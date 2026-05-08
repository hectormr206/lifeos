/* nix/disko/vm.nix
 *
 * Disko declarative partition layout for the LifeOS development VM.
 *
 * Layout:
 *   /dev/vda (80 GB virtual disk, qemu/KVM default)
 *   ├── ESP: 1 GB FAT32 → /boot
 *   └── Btrfs: remainder
 *       ├── @      → /              (compress=zstd noatime)
 *       ├── @home  → /home          (compress=zstd noatime)
 *       ├── @nix   → /nix           (compress=zstd noatime)
 *       └── @data  → /var/lib/lifeos (compress=zstd noatime)
 *
 * zram swap: enabled (no swap partition — REQ-6.1)
 *
 * NOTE: @data is declared here for structural consistency with the laptop
 * layout. On the VM it starts empty. On the laptop (Phase C), a wrapper
 * script preserves @data contents across reinstalls (REQ-6.3, REQ-6.4).
 *
 * Satisfies: REQ-6.1
 */
{ disks ? [ "/dev/vda" ], ... }:
{
  disko.devices = {
    disk.main = {
      type = "disk";
      device = builtins.head disks;
      content = {
        type = "gpt";
        partitions = {
          # EFI System Partition
          ESP = {
            size = "1G";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "defaults" ];
            };
          };

          # Btrfs root — all subvolumes in a single partition
          root = {
            size = "100%";
            content = {
              type = "btrfs";
              extraArgs = [ "-f" "-L" "lifeos-root" ];
              subvolumes = {
                # System root
                "@" = {
                  mountpoint = "/";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                # User homes
                "@home" = {
                  mountpoint = "/home";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                # Nix store — often has many small files; noatime is important
                "@nix" = {
                  mountpoint = "/nix";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
                # LifeOS persistent data (memory DB, models, SimplexDB)
                # Declared as its own subvolume so Phase C reinstalls can
                # preserve it independently of the system subvolumes.
                "@data" = {
                  mountpoint = "/var/lib/lifeos";
                  mountOptions = [ "compress=zstd" "noatime" ];
                };
              };
            };
          };
        };
      };
    };
  };
}
