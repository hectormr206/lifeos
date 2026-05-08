/* nix/modules/lifeos-defaults.nix
 *
 * LifeOS baseline: system user/group, tmpfiles rules, /etc/lifeos directory.
 *
 * Every LifeOS host imports this module. It does NOT enable any service.
 * It only provisions the shared filesystem structure that all services depend on.
 *
 * Key constraints:
 * - lifeos user has FIXED UID 970 (required by Phase 8b SO_PEERCRED auth)
 * - lifeos group has FIXED GID 970
 * - /var/lib/lifeos and subdirs created by tmpfiles (no manual mkdir needed)
 * - No reboot needed after nixos-rebuild switch (tmpfiles runs at activation)
 *
 * Satisfies: REQ-3.3, REQ-3.5
 */
{ config, lib, pkgs, ... }:
{
  # Fixed UID/GID for SO_PEERCRED predictability (D-4 in decisions log)
  users.users.lifeos = {
    isSystemUser = true;
    group = "lifeos";
    home = "/var/lib/lifeos";
    uid = 970;
    description = "LifeOS system user";
    # nologin shell for non-interactive system user
    shell = "${pkgs.shadow}/bin/nologin";
  };

  users.groups.lifeos = {
    gid = 970;
  };

  # tmpfiles: create all required directories at activation time.
  # No reboot, no manual chown. REQ-3.3, REQ-3.5.
  systemd.tmpfiles.rules = [
    # Main data directory
    "d /var/lib/lifeos             0750 lifeos lifeos -"
    "d /var/lib/lifeos/memory      0750 lifeos lifeos -"
    "d /var/lib/lifeos/embeddings  0750 lifeos lifeos -"
    "d /var/lib/lifeos/models      0750 lifeos lifeos -"
    "d /var/lib/lifeos/simplex     0750 lifeos lifeos -"
    # Config directory — readable by root and lifeos group
    "d /etc/lifeos                 0755 root   root   -"
    # Runtime socket directory — created by RuntimeDirectory, but tmpfiles
    # ensures it exists with correct perms even before first service start
    "d /run/lifeos                 0750 lifeos lifeos -"
  ];
}
