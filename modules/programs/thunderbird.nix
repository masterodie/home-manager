{ config, lib, pkgs, ... }:

with lib;

let
  inherit (pkgs.stdenv.hostPlatform) isDarwin;

  cfg = config.programs.thunderbird;

  enabledAccounts = attrValues
    (filterAttrs (_: a: a.thunderbird.enable) config.accounts.email.accounts);

  enabledAccountsWithId =
    map (a: a // { id = builtins.hashString "sha256" a.name; }) enabledAccounts;

  thunderbirdConfigPath =
    if isDarwin then "Library/Thunderbird" else ".thunderbird";

  thunderbirdProfilesPath = if isDarwin then
    "${thunderbirdConfigPath}/Profiles"
  else
    thunderbirdConfigPath;

  profilesWithId =
    imap0 (i: v: v // { id = toString i; }) (attrValues cfg.profiles);

  profilesIni = foldl recursiveUpdate {
    General = {
      StartWithLastProfile = 1;
      Version = 2;
    };
  } (flip map profilesWithId (profile: {
    "Profile${profile.id}" = {
      Name = profile.name;
      Path = if isDarwin then "Profiles/${profile.name}" else profile.name;
      IsRelative = 1;
      Default = if profile.isDefault then 1 else 0;
    };
  }));

  toThunderbirdAccount = account: profile:
    let id = account.id;
    in {
      "mail.account.account_${id}.identities" = "id_${id}";
      "mail.account.account_${id}.server" = "server_${id}";
      "mail.identity.id_${id}.fullName" = account.realName;
      "mail.identity.id_${id}.useremail" = account.address;
      "mail.identity.id_${id}.valid" = true;
    } // optionalAttrs account.primary {
      "mail.accountmanager.defaultaccount" = "account_${id}";
    } // optionalAttrs (account.gpg != null) {
      "mail.identity.id_${id}.attachPgpKey" = false;
      "mail.identity.id_${id}.autoEncryptDrafts" = true;
      "mail.identity.id_${id}.e2etechpref" = 0;
      "mail.identity.id_${id}.encryptionpolicy" =
        if account.gpg.encryptByDefault then 2 else 0;
      "mail.identity.id_${id}.is_gnupg_key_id" = true;
      "mail.identity.id_${id}.last_entered_external_gnupg_key_id" =
        account.gpg.key;
      "mail.identity.id_${id}.openpgp_key_id" = account.gpg.key;
      "mail.identity.id_${id}.protectSubject" = true;
      "mail.identity.id_${id}.sign_mail" = account.gpg.signByDefault;
    } // optionalAttrs (account.imap != null) {
      "mail.server.server_${id}.directory" =
        "${thunderbirdProfilesPath}/${profile.name}/ImapMail/${id}";
      "mail.server.server_${id}.directory-rel" = "[ProfD]ImapMail/${id}";
      "mail.server.server_${id}.hostname" = account.imap.host;
      "mail.server.server_${id}.login_at_startup" = true;
      "mail.server.server_${id}.name" = account.name;
      "mail.server.server_${id}.port" =
        if (account.imap.port != null) then account.imap.port else 143;
      "mail.server.server_${id}.socketType" = if !account.imap.tls.enable then
        0
      else if account.imap.tls.useStartTls then
        2
      else
        3;
      "mail.server.server_${id}.type" = "imap";
      "mail.server.server_${id}.userName" = account.userName;
    } // optionalAttrs (account.smtp != null) {
      "mail.identity.id_${id}.smtpServer" = "smtp_${id}";
      "mail.smtpserver.smtp_${id}.authMethod" = 3;
      "mail.smtpserver.smtp_${id}.hostname" = account.smtp.host;
      "mail.smtpserver.smtp_${id}.port" =
        if (account.smtp.port != null) then account.smtp.port else 587;
      "mail.smtpserver.smtp_${id}.try_ssl" = if !account.smtp.tls.enable then
        0
      else if account.smtp.tls.useStartTls then
        2
      else
        3;
      "mail.smtpserver.smtp_${id}.username" = account.userName;
    } // optionalAttrs (account.smtp != null && account.primary) {
      "mail.smtp.defaultserver" = "smtp_${id}";
    } // account.thunderbird.settings id;

  mkUserJs = prefs: ''
    // Generated by Home Manager.

    ${concatStrings (mapAttrsToList (name: value: ''
      user_pref("${name}", ${builtins.toJSON value});
    '') prefs)}
  '';
in {
  meta.maintainers = with hm.maintainers; [ d-dervishi jkarlson ];

  options = {
    programs.thunderbird = {
      enable = mkEnableOption "Thunderbird";

      package = mkOption {
        type = types.package;
        default = pkgs.thunderbird;
        defaultText = literalExpression "pkgs.thunderbird";
        example = literalExpression "pkgs.thunderbird-91";
        description = "The Thunderbird package to use.";
      };

      profiles = mkOption {
        type = with types;
          attrsOf (submodule ({ config, name, ... }: {
            options = {
              name = mkOption {
                type = types.str;
                default = name;
                readOnly = true;
                description = "This profile's name.";
              };

              isDefault = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = ''
                  Whether this is a default profile. There must be exactly one
                  default profile.
                '';
              };

              settings = mkOption {
                type = with types; attrsOf (oneOf [ bool int str ]);
                default = { };
                example = literalExpression ''
                  {
                    "mail.spellcheck.inline" = false;
                  }
                '';
                description = ''
                  Preferences to add to this profile's
                  <filename>user.js</filename>.
                '';
              };

              withExternalGnupg = mkOption {
                type = types.bool;
                default = false;
                example = true;
                description = "Allow using external GPG keys with GPGME.";
              };
            };
          }));
      };

      settings = mkOption {
        type = with types; attrsOf (oneOf [ bool int str ]);
        default = { };
        example = literalExpression ''
          {
            "general.useragent.override" = "";
            "privacy.donottrackheader.enabled" = true;
          }
        '';
        description = ''
          Attribute set of Thunderbird preferences to be added to
          all profiles.
        '';
      };

      darwinSetupWarning = mkOption {
        type = types.bool;
        default = true;
        example = false;
        visible = isDarwin;
        readOnly = !isDarwin;
        description = ''
          Warn to set environment variables before using this module. Only
          relevant on Darwin.
        '';
      };
    };

    accounts.email.accounts = mkOption {
      type = with types;
        attrsOf (submodule {
          options.thunderbird = {
            enable =
              mkEnableOption "the Thunderbird mail client for this account";

            profiles = mkOption {
              type = with types; listOf str;
              default = [ ];
              example = literalExpression ''
                [ "profile1" "profile2" ]
              '';
              description = ''
                List of Thunderbird profiles for which this account should be
                enabled. If this list is empty (the default), this account will
                be enabled for all declared profiles.
              '';
            };

            settings = mkOption {
              type = with types; functionTo (attrsOf (oneOf [ bool int str ]));
              default = _: { };
              defaultText = literalExpression "_: { }";
              example = literalExpression ''
                id: {
                  "mail.identity.id_''${id}.protectSubject" = false;
                  "mail.identity.id_''${id}.autoEncryptDrafts" = false;
                };
              '';
              description = ''
                Extra settings to add to this Thunderbird account configuration.
                The <varname>id</varname> given as argument is an automatically
                generated account identifier.
              '';
            };
          };
        });
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      (let defaults = catAttrs "name" (filter (a: a.isDefault) profilesWithId);
      in {
        assertion = cfg.profiles == { } || length defaults == 1;
        message = "Must have exactly one default Thunderbird profile but found "
          + toString (length defaults) + optionalString (length defaults > 1)
          (", namely " + concatStringsSep "," defaults);
      })

      (let
        profiles = catAttrs "name" profilesWithId;
        selectedProfiles =
          concatMap (a: a.thunderbird.profiles) enabledAccounts;
      in {
        assertion = (intersectLists profiles selectedProfiles)
          == selectedProfiles;
        message = "Cannot enable an account for a non-declared profile. "
          + "The declared profiles are " + (concatStringsSep "," profiles)
          + ", but the used profiles are "
          + (concatStringsSep "," selectedProfiles);
      })
    ];

    warnings = optional (isDarwin && cfg.darwinSetupWarning) ''
      Thunderbird packages are not yet supported on Darwin. You can still use
      this module to manage your accounts and profiles by setting
      'programs.thunderbird.package' to a dummy value, for example using
      'pkgs.runCommand'.

      Note that this module requires you to set the following environment
      variables when using an installation of Thunderbird that is not provided
      by Nix:

          export MOZ_LEGACY_PROFILES=1
          export MOZ_ALLOW_DOWNGRADE=1
    '';

    home.packages = [ cfg.package ]
      ++ optional (any (p: p.withExternalGnupg) (attrValues cfg.profiles))
      pkgs.gpgme;

    home.file = mkMerge ([{
      "${thunderbirdConfigPath}/profiles.ini" =
        mkIf (cfg.profiles != { }) { text = generators.toINI { } profilesIni; };
    }] ++ flip mapAttrsToList cfg.profiles (name: profile: {
      "${thunderbirdProfilesPath}/${name}/user.js" = let
        accounts = filter (a:
          a.thunderbird.profiles == [ ]
          || any (p: p == name) a.thunderbird.profiles) enabledAccountsWithId;

        smtp = filter (a: a.smtp != null) accounts;
      in {
        text = mkUserJs (builtins.foldl' (a: b: a // b) { } ([
          cfg.settings

          (optionalAttrs (length accounts != 0) {
            "mail.accountmanager.accounts" =
              concatStringsSep "," (map (a: "account_${a.id}") accounts);
          })

          (optionalAttrs (length smtp != 0) {
            "mail.smtpservers" =
              concatStringsSep "," (map (a: "smtp_${a.id}") smtp);
          })

          { "mail.openpgp.allow_external_gnupg" = profile.withExternalGnupg; }

          profile.settings
        ] ++ (map (a: toThunderbirdAccount a profile) accounts)));
      };
    }));
  };
}
