{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hardware.deviceTree;

  buildExtraPreprocessorFlags = mkOption {
    default = [];
    example = literalExpression "[ \"-DMY_DTB_DEFINE\" ]";
    type = types.listOf types.str;
    description = lib.mdDoc ''
      Additional flags to pass to the preprocessor during .dtb/.dtbo compilations
    '';
  };

  buildExtraIncludePaths = mkOption {
    default = [];
    example = literalExpression ''
      [
        ./my_custom_include_dir_1
        ./custom_include_dir_2
      ]
    '';
    type = types.listOf types.path;
    description = lib.mdDoc ''
      Additional include paths that will be passed to the preprocessor when creating the final .dts to compile into .dtbo/.dtb
    '';
  };

  dtsSourceType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = lib.mdDoc ''
          Name of the dts source
        '';
      };
      
      dtsFile = mkOption {
        type = types.nullOr types.path;
        description = lib.mdDoc ''
          Path to .dts source file that will be compiled into the .dtb that is served as the base to apply overlay to. Take precedence over the {option}`dtsText` option.
        '';
        default = null;
        example = literalExpression "./dts/top-level.dts";
      };

      dtsText = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = lib.mdDoc ''
          Literal DTS contents that will be compiled into the .dtb that is served as the base to apply overlays to. Will be ignored if {option}`dtsFile` option is also specified.
        '';
        example = ''
          /dts-v1/;

          #include "zynqmp.dtsi"
          #include <dt-bindings/pinctrl/pinctrl-zynqmp.h>
          #include <dt-bindings/phy/phy.h>

          / {
            model = "ZynqMP ZCU208 RevA";
            compatible = "xlnx,zynqmp-zcu208-revA";

            aliases {
              ethernet0 = &gem3;
              i2c0 = &i2c0;
              i2c1 = &i2c1;
            };

            chosen {
              bootargs = "earlycon";
              stdout-path = "serial0:115200n8";
            };

            memory@0 {
              device_type = "memory";
              reg = <0x0 0x0 0x0 0x80000000>, <0x8 0x00000000 0x0 0x80000000>;
            };
          };
        '';
      };

      inherit buildExtraPreprocessorFlags buildExtraIncludePaths;
    };
  };

  overlayType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = lib.mdDoc ''
          Name of this overlay
        '';
      };

      filter = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "*rpi*.dtb";
        description = lib.mdDoc ''
          Only apply to .dtb files matching glob expression.
        '';
      };

      dtsFile = mkOption {
        type = types.nullOr types.path;
        description = lib.mdDoc ''
          Path to .dts overlay file, overlay is applied to
          each .dtb file matching "compatible" of the overlay.
        '';
        default = null;
        example = literalExpression "./dts/overlays.dts";
      };

      dtsText = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = lib.mdDoc ''
          Literal DTS contents, overlay is applied to
          each .dtb file matching "compatible" of the overlay.
        '';
        example = ''
          /dts-v1/;
          /plugin/;
          / {
                  compatible = "raspberrypi";
          };
          &{/soc} {
                  pps {
                          compatible = "pps-gpio";
                          status = "okay";
                  };
          };
        '';
      };

      dtboFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = lib.mdDoc ''
          Path to .dtbo compiled overlay file.
        '';
      };

      inherit buildExtraPreprocessorFlags buildExtraIncludePaths;
    };
  };

  filterDTBs = src: if cfg.filter == null
    then src
    else
      pkgs.runCommand "dtbs-filtered" {} ''
        mkdir -p $out
        cd ${src}
        find . -type f -name '${cfg.filter}' -print0 \
          | xargs -0 cp -v --no-preserve=mode --target-directory $out --parents
      '';

  filteredDTBs = filterDTBs cfg.dtbSource;
  
  dtbFromDtsSrc = buildDtb {
    name = "${cfg.dtsSource.name}.dtb";
    dtsFile = if cfg.dtsSource.dtsFile == null then (pkgs.writeText "dts" cfg.dtsSource.dtsText) else cfg.dtsSource.dtsFile;
    inherit (cfg.dtsSource) buildExtraPreprocessorFlags buildExtraIncludePaths;
  };

  buildDtb = { name, dtsFile, buildExtraIncludePaths, buildExtraPreprocessorFlags }:
    let
      includePaths = ["${getDev cfg.kernelPackage}/lib/modules/${cfg.kernelPackage.modDirVersion}/source/scripts/dtc/include-prefixes"] ++ buildExtraIncludePaths;
      extraPreprocessorFlags = buildExtraPreprocessorFlags;
    in
      pkgs.deviceTree.compileDTS {
        inherit name includePaths dtsFile extraPreprocessorFlags;
      };

  # Fill in `dtboFile` for each overlay if not set already.
  # Existence of one of these is guarded by assertion below
  withDTBOs = xs: flip map xs (o: o // { dtboFile =
    if o.dtboFile == null then
      let
        name = "${o.name}-dtbo";
        dtsFile = if o.dtsFile == null then (pkgs.writeText "dts" o.dtsText) else o.dtsFile;
      in
      buildDtb {
        inherit name dtsFile;
        inherit (o) buildExtraPreprocessorFlags buildExtraIncludePaths;
      }
    else o.dtboFile; } );

in
{
  imports = [
    (mkRemovedOptionModule [ "hardware" "deviceTree" "base" ] "Use hardware.deviceTree.kernelPackage instead")
  ];

  options = {
      hardware.deviceTree = {
        enable = mkOption {
          default = pkgs.stdenv.hostPlatform.linux-kernel.DTB or false;
          type = types.bool;
          description = lib.mdDoc ''
            Build device tree files. These are used to describe the
            non-discoverable hardware of a system.
          '';
        };

        kernelPackage = mkOption {
          default = config.boot.kernelPackages.kernel;
          defaultText = literalExpression "config.boot.kernelPackages.kernel";
          example = literalExpression "pkgs.linux_latest";
          type = types.path;
          description = lib.mdDoc ''
            Kernel package where device tree include directory is from. Also used as default source of dtb package to apply overlays to
          '';
        };

        dtsSource = mkOption {
          default = null;
          type = types.nullOr dtsSourceType;
          description = lib.mdDoc ''
            Dts source that is used to compile into .dtb that serves as base to apply overlay to. This will take precedence over the {option}`hardware.deviceTree.dtbSource` option if both are specified.
          '';
        };

        dtbSource = mkOption {
          default = "${cfg.kernelPackage}/dtbs";
          defaultText = literalExpression "\${cfg.kernelPackage}/dtbs";
          type = types.path;
          description = lib.mdDoc ''
            Path to dtb directory that overlays and other processing will be applied to. Uses
            device trees bundled with the Linux kernel by default. Will be ignored if {option}`hardware.deviceTree.dtsSource` is also specified.
          '';
        };

        name = mkOption {
          default = null;
          example = "some-dtb.dtb";
          type = types.nullOr types.str;
          description = lib.mdDoc ''
            The name of an explicit dtb to be loaded, relative to the dtb base.
            Useful in extlinux scenarios if the bootloader doesn't pick the
            right .dtb file from FDTDIR.
          '';
        };

        filter = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "*rpi*.dtb";
          description = lib.mdDoc ''
            Only include .dtb files matching glob expression. Only used with {option}`hardware.deviceTree.dtbSource` option
          '';
        };

        overlays = mkOption {
          default = [];
          example = literalExpression ''
            [
              { name = "pps"; dtsFile = ./dts/pps.dts; }
              { name = "spi";
                dtsText = "...";
              }
              { name = "precompiled"; dtboFile = ./dtbos/example.dtbo; }
            ]
          '';
          type = types.listOf (types.coercedTo types.path (path: {
            name = baseNameOf path;
            filter = null;
            dtboFile = path;
          }) overlayType);
          description = lib.mdDoc ''
            List of overlays to apply to base device-tree (.dtb) files.
          '';
        };

        package = mkOption {
          default = null;
          type = types.nullOr types.path;
          internal = true;
          description = lib.mdDoc ''
            A path containing the result of applying `overlays` to `kernelPackage`.
          '';
        };
      };
  };

  config = mkIf (cfg.enable) {

    assertions = let
      invalidOverlay = o: (o.dtsFile == null) && (o.dtsText == null) && (o.dtboFile == null);
    in lib.singleton {
      assertion = lib.all (o: !invalidOverlay o) cfg.overlays;
      message = ''
        deviceTree overlay needs one of dtsFile, dtsText or dtboFile set.
        Offending overlay(s):
        ${toString (map (o: o.name) (builtins.filter invalidOverlay cfg.overlays))}
      '';
    };

    hardware.deviceTree.package = 
      let 
        finalDtbSource = 
          if cfg.dtsSource == null 
          then filteredDTBs 
          else pkgs.runCommand "${cfg.dtsSource.name}-dtb-dir" {} ''
            # put the compiled Dtb into a directory
            # since applyOverlays expect a dir
            mkdir -p $out
            cp ${dtbFromDtsSrc} $out/${cfg.dtsSource.name}.dtb
          '';
      in
        if (cfg.overlays != [])
          then pkgs.deviceTree.applyOverlays finalDtbSource (withDTBOs cfg.overlays)
          else finalDtbSource;
  };
}
