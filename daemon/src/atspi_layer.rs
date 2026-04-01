//! AT-SPI2 Accessibility Layer — Layer 3 in the LifeOS control hierarchy.
//!
//! Uses the `atspi` crate (pure Rust, zbus-based) to navigate application
//! accessibility trees on Linux. This enables:
//! - Reading UI element trees (buttons, menus, text fields)
//! - Finding elements by role and name
//! - Activating elements (click, press)
//! - Reading/writing text content
//!
//! GTK4/libadwaita apps expose complete AT-SPI2 trees. COSMIC (iced-based)
//! apps have partial support. Falls back to Layer 4 (Vision+Input) when
//! AT-SPI2 is unavailable.

#[cfg(feature = "dbus")]
mod inner {
    use anyhow::{anyhow, Context, Result};
    use atspi::proxy::accessible::AccessibleProxy;
    use atspi::AccessibilityConnection;
    use log::{debug, info, warn};
    use serde::{Deserialize, Serialize};

    /// Represents a node in an application's accessibility tree.
    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct A11yNode {
        pub name: String,
        pub role: String,
        pub path: String,
        pub bus_name: String,
        pub children: Vec<A11yNode>,
        pub child_count: i32,
    }

    /// A reference to a D-Bus object (bus name + path), owned.
    #[derive(Clone)]
    struct ObjRef {
        bus: String,
        path: zbus::zvariant::OwnedObjectPath,
    }

    async fn connect() -> Result<AccessibilityConnection> {
        AccessibilityConnection::new()
            .await
            .context("Failed to connect to AT-SPI2 bus. Is at-spi2-core running?")
    }

    /// Build an AccessibleProxy from owned bus name and path.
    async fn accessible_proxy(
        conn: &zbus::Connection,
        obj: &ObjRef,
    ) -> Option<AccessibleProxy<'static>> {
        // Use OwnedBusName for 'static lifetime
        let bus_name: zbus::names::OwnedBusName = obj.bus.as_str().try_into().ok()?;
        AccessibleProxy::builder(conn)
            .destination(bus_name)
            .ok()?
            .path(obj.path.clone())
            .ok()?
            .build()
            .await
            .ok()
    }

    /// Get children as owned references to avoid lifetime issues.
    async fn get_children_owned(conn: &zbus::Connection, obj: &ObjRef) -> Vec<ObjRef> {
        let proxy = match accessible_proxy(conn, obj).await {
            Some(p) => p,
            None => return Vec::new(),
        };

        match proxy.get_children().await {
            Ok(children) => children
                .into_iter()
                .map(|c| ObjRef {
                    bus: c.name.to_string(),
                    path: c.path,
                })
                .collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Read accessible name and role from a proxy.
    async fn read_node_info(
        conn: &zbus::Connection,
        obj: &ObjRef,
    ) -> Option<(String, String, i32)> {
        let proxy = accessible_proxy(conn, obj).await?;
        let name = proxy.name().await.unwrap_or_default();
        let role = proxy
            .get_role_name()
            .await
            .unwrap_or_else(|_| "unknown".to_string());
        let count = proxy.child_count().await.unwrap_or(0);
        Some((name, role, count))
    }

    /// Build accessibility tree iteratively using a stack (avoids recursive async).
    async fn build_tree(conn: &zbus::Connection, root: ObjRef, max_depth: u32) -> Result<A11yNode> {
        // We use a simple BFS with depth tracking.
        // First pass: collect all nodes and their children refs.
        struct PendingNode {
            obj: ObjRef,
            depth: u32,
            parent_idx: Option<usize>,
        }

        struct CollectedNode {
            name: String,
            role: String,
            path: String,
            bus_name: String,
            child_count: i32,
            child_indices: Vec<usize>,
        }

        let mut queue: Vec<PendingNode> = vec![PendingNode {
            obj: root,
            depth: 0,
            parent_idx: None,
        }];
        let mut collected: Vec<CollectedNode> = Vec::new();

        let mut i = 0;
        while i < queue.len() {
            let obj = queue[i].obj.clone();
            let depth = queue[i].depth;
            let my_idx = collected.len();

            let (name, role, child_count) = read_node_info(conn, &obj)
                .await
                .unwrap_or_else(|| (String::new(), "unknown".to_string(), 0));

            collected.push(CollectedNode {
                name,
                role,
                path: obj.path.to_string(),
                bus_name: obj.bus.clone(),
                child_count,
                child_indices: Vec::new(),
            });

            // Record this node as a child of its parent
            if let Some(parent_idx) = queue[i].parent_idx {
                collected[parent_idx].child_indices.push(my_idx);
            }

            // Expand children if within depth limit
            if depth < max_depth {
                let children = get_children_owned(conn, &obj).await;
                for child in children {
                    queue.push(PendingNode {
                        obj: child,
                        depth: depth + 1,
                        parent_idx: Some(my_idx),
                    });
                }
            }

            i += 1;
            // Safety limit: don't enumerate more than 500 nodes
            if collected.len() > 500 {
                break;
            }
        }

        // Second pass: build the tree bottom-up
        fn build_from(collected: &[CollectedNode], idx: usize) -> A11yNode {
            let node = &collected[idx];
            let children: Vec<A11yNode> = node
                .child_indices
                .iter()
                .map(|&ci| build_from(collected, ci))
                .collect();
            A11yNode {
                name: node.name.clone(),
                role: node.role.clone(),
                path: node.path.clone(),
                bus_name: node.bus_name.clone(),
                child_count: node.child_count,
                children,
            }
        }

        if collected.is_empty() {
            return Err(anyhow!("No nodes found"));
        }

        Ok(build_from(&collected, 0))
    }

    /// Get the accessibility tree for an application, up to `max_depth` levels.
    pub async fn get_tree(app_name: &str, max_depth: u32) -> Result<Vec<A11yNode>> {
        let conn = connect().await?;
        let dbus_conn = conn.connection();

        let registry = AccessibleProxy::builder(dbus_conn)
            .destination("org.a11y.atspi.Registry")?
            .path("/org/a11y/atspi/accessible/root")?
            .build()
            .await
            .context("Failed to access AT-SPI2 registry")?;

        let children: Vec<ObjRef> = registry
            .get_children()
            .await
            .context("Failed to list AT-SPI2 applications")?
            .into_iter()
            .map(|c| ObjRef {
                bus: c.name.to_string(),
                path: c.path,
            })
            .collect();

        let app_lower = app_name.to_lowercase();
        let mut results = Vec::new();

        for child in &children {
            let (name, _, _) = match read_node_info(dbus_conn, child).await {
                Some(info) => info,
                None => continue,
            };

            if !app_name.is_empty() && !name.to_lowercase().contains(&app_lower) {
                continue;
            }

            match build_tree(dbus_conn, child.clone(), max_depth).await {
                Ok(node) => results.push(node),
                Err(e) => debug!("[atspi] Skipping app: {}", e),
            }
        }

        if results.is_empty() && !app_name.is_empty() {
            info!(
                "[atspi] No application found matching '{}'. {} apps on bus.",
                app_name,
                children.len()
            );
        }

        Ok(results)
    }

    /// Find elements matching a role and/or name in an application's tree.
    pub async fn find_elements(
        app_name: &str,
        role_filter: Option<&str>,
        name_filter: Option<&str>,
    ) -> Result<Vec<A11yNode>> {
        let trees = get_tree(app_name, 10).await?;
        let mut matches = Vec::new();

        for tree in &trees {
            collect_matches(tree, role_filter, name_filter, &mut matches);
        }

        info!(
            "[atspi] find_elements(app={}, role={:?}, name={:?}) -> {} matches",
            app_name,
            role_filter,
            name_filter,
            matches.len()
        );

        Ok(matches)
    }

    fn collect_matches(
        node: &A11yNode,
        role_filter: Option<&str>,
        name_filter: Option<&str>,
        results: &mut Vec<A11yNode>,
    ) {
        let role_match = role_filter
            .map(|r| node.role.to_lowercase().contains(&r.to_lowercase()))
            .unwrap_or(true);
        let name_match = name_filter
            .map(|n| node.name.to_lowercase().contains(&n.to_lowercase()))
            .unwrap_or(true);

        if role_match && name_match {
            results.push(A11yNode {
                name: node.name.clone(),
                role: node.role.clone(),
                path: node.path.clone(),
                bus_name: node.bus_name.clone(),
                children: Vec::new(),
                child_count: node.child_count,
            });
        }

        for child in &node.children {
            collect_matches(child, role_filter, name_filter, results);
        }
    }

    /// Activate (click/press) an accessibility element by its D-Bus path.
    pub async fn activate_element(bus_name: &str, path: &str) -> Result<()> {
        let conn = connect().await?;
        let dbus_conn = conn.connection();

        let action_proxy = atspi::proxy::action::ActionProxy::builder(dbus_conn)
            .destination(bus_name)?
            .path(path)?
            .build()
            .await
            .context("Failed to build Action proxy")?;

        let n_actions = action_proxy.nactions().await.unwrap_or(0);
        if n_actions == 0 {
            return Err(anyhow!("Element at {} has no available actions", path));
        }

        action_proxy
            .do_action(0)
            .await
            .context("Failed to perform action on element")?;

        info!("[atspi] Activated element at {}:{}", bus_name, path);
        Ok(())
    }

    /// Get the text content of an accessibility element.
    pub async fn get_text(bus_name: &str, path: &str) -> Result<String> {
        let conn = connect().await?;
        let dbus_conn = conn.connection();

        let text_proxy = atspi::proxy::text::TextProxy::builder(dbus_conn)
            .destination(bus_name)?
            .path(path)?
            .build()
            .await
            .context("Failed to build Text proxy")?;

        let char_count = text_proxy.character_count().await.unwrap_or(0);
        if char_count == 0 {
            return Ok(String::new());
        }

        let text = text_proxy
            .get_text(0, char_count)
            .await
            .context("Failed to get text content")?;

        Ok(text)
    }

    /// Set the text content of an editable accessibility element.
    pub async fn set_text(bus_name: &str, path: &str, text: &str) -> Result<()> {
        let conn = connect().await?;
        let dbus_conn = conn.connection();

        let editable_proxy = atspi::proxy::editable_text::EditableTextProxy::builder(dbus_conn)
            .destination(bus_name)?
            .path(path)?
            .build()
            .await
            .context("Failed to build EditableText proxy — element may not be editable")?;

        let text_proxy = atspi::proxy::text::TextProxy::builder(dbus_conn)
            .destination(bus_name)?
            .path(path)?
            .build()
            .await?;

        let char_count = text_proxy.character_count().await.unwrap_or(0);
        if char_count > 0 {
            editable_proxy.delete_text(0, char_count).await?;
        }

        editable_proxy
            .insert_text(0, text, text.len() as i32)
            .await?;

        info!(
            "[atspi] Set text on {}:{} ({} chars)",
            bus_name,
            path,
            text.len()
        );
        Ok(())
    }

    /// List all applications currently registered on the AT-SPI2 bus.
    pub async fn list_applications() -> Result<Vec<String>> {
        let conn = connect().await?;
        let dbus_conn = conn.connection();

        let registry = AccessibleProxy::builder(dbus_conn)
            .destination("org.a11y.atspi.Registry")?
            .path("/org/a11y/atspi/accessible/root")?
            .build()
            .await
            .context("Failed to access AT-SPI2 registry")?;

        let children: Vec<ObjRef> = registry
            .get_children()
            .await?
            .into_iter()
            .map(|c| ObjRef {
                bus: c.name.to_string(),
                path: c.path,
            })
            .collect();

        let mut apps = Vec::new();
        for child in &children {
            if let Some((name, _, _)) = read_node_info(dbus_conn, child).await {
                if !name.is_empty() {
                    apps.push(name);
                }
            }
        }

        info!("[atspi] {} applications on AT-SPI2 bus", apps.len());
        Ok(apps)
    }

    /// Check if AT-SPI2 is available on this system.
    pub async fn is_available() -> bool {
        match connect().await {
            Ok(_) => {
                debug!("[atspi] AT-SPI2 bus is available");
                true
            }
            Err(e) => {
                warn!("[atspi] AT-SPI2 not available: {}", e);
                false
            }
        }
    }
}

#[cfg(feature = "dbus")]
pub use inner::*;

#[cfg(not(feature = "dbus"))]
mod stub {
    use anyhow::{anyhow, Result};
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Clone, Serialize, Deserialize)]
    pub struct A11yNode {
        pub name: String,
        pub role: String,
        pub path: String,
        pub bus_name: String,
        pub children: Vec<A11yNode>,
        pub child_count: i32,
    }

    pub async fn get_tree(_app: &str, _depth: u32) -> Result<Vec<A11yNode>> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn find_elements(
        _app: &str,
        _role: Option<&str>,
        _name: Option<&str>,
    ) -> Result<Vec<A11yNode>> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn activate_element(_bus: &str, _path: &str) -> Result<()> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn get_text(_bus: &str, _path: &str) -> Result<String> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn set_text(_bus: &str, _path: &str, _text: &str) -> Result<()> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn list_applications() -> Result<Vec<String>> {
        Err(anyhow!("AT-SPI2 requires the 'dbus' feature"))
    }

    pub async fn is_available() -> bool {
        false
    }
}

#[cfg(not(feature = "dbus"))]
pub use stub::*;
