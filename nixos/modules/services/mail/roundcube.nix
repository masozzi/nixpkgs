{ lib, config, pkgs, ... }:

with lib;

let
  cfg = config.services.roundcube;
  fpm = config.services.phpfpm.pools.roundcube;
  localDB = cfg.database.host == "localhost";
  user = cfg.database.username;
  phpWithPspell = pkgs.php83.withExtensions ({ enabled, all }: [ all.pspell ] ++ enabled);
in
{
  options.services.roundcube = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to enable roundcube.

        Also enables nginx virtual host management.
        Further nginx configuration can be done by adapting `services.nginx.virtualHosts.<name>`.
        See [](#opt-services.nginx.virtualHosts) for further information.
      '';
    };

    hostName = mkOption {
      type = types.str;
      example = "webmail.example.com";
      description = "Hostname to use for the nginx vhost";
    };

    package = mkPackageOption pkgs "roundcube" {
      example = "roundcube.withPlugins (plugins: [ plugins.persistent_login ])";
    };

    database = {
      username = mkOption {
        type = types.str;
        default = "roundcube";
        description = ''
          Username for the postgresql connection.
          If `database.host` is set to `localhost`, a unix user and group of the same name will be created as well.
        '';
      };
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = ''
          Host of the postgresql server. If this is not set to
          `localhost`, you have to create the
          postgresql user and database yourself, with appropriate
          permissions.
        '';
      };
      password = mkOption {
        type = types.str;
        description = "Password for the postgresql connection. Do not use: the password will be stored world readable in the store; use `passwordFile` instead.";
        default = "";
      };
      passwordFile = mkOption {
        type = types.str;
        description = ''
          Password file for the postgresql connection.
          Must be formatted according to PostgreSQL .pgpass standard (see https://www.postgresql.org/docs/current/libpq-pgpass.html)
          but only one line, no comments and readable by user `nginx`.
          Ignored if `database.host` is set to `localhost`, as peer authentication will be used.
        '';
      };
      dbname = mkOption {
        type = types.str;
        default = "roundcube";
        description = "Name of the postgresql database";
      };
    };

    plugins = mkOption {
      type = types.listOf types.str;
      default = [];
      description = ''
        List of roundcube plugins to enable. Currently, only those directly shipped with Roundcube are supported.
      '';
    };

    dicts = mkOption {
      type = types.listOf types.package;
      default = [];
      example = literalExpression "with pkgs.aspellDicts; [ en fr de ]";
      description = ''
        List of aspell dictionaries for spell checking. If empty, spell checking is disabled.
      '';
    };

    maxAttachmentSize = mkOption {
      type = types.int;
      default = 18;
      description = ''
        The maximum attachment size in MB.

        Note: Since roundcube only uses 70% of max upload values configured in php
        30% is added automatically to [](#opt-services.roundcube.maxAttachmentSize).
      '';
      apply = configuredMaxAttachmentSize: "${toString (configuredMaxAttachmentSize * 1.3)}M";
    };

    configureNginx = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Configure nginx as a reverse proxy for roundcube.";
    };

    extraConfig = mkOption {
      type = types.lines;
      default = "";
      description = "Extra configuration for roundcube webmail instance";
    };
  };

  config = mkIf cfg.enable {
    # backward compatibility: if password is set but not passwordFile, make one.
    services.roundcube.database.passwordFile = mkIf (!localDB && cfg.database.password != "") (mkDefault ("${pkgs.writeText "roundcube-password" cfg.database.password}"));
    warnings = lib.optional (!localDB && cfg.database.password != "") "services.roundcube.database.password is deprecated and insecure; use services.roundcube.database.passwordFile instead";

    environment.etc."roundcube/config.inc.php".text = ''
      <?php

      ${lib.optionalString (!localDB) ''
        $password = file('${cfg.database.passwordFile}')[0];
        $password = preg_split('~\\\\.(*SKIP)(*FAIL)|\:~s', $password);
        $password = rtrim(end($password));
        $password = str_replace("\\:", ":", $password);
        $password = str_replace("\\\\", "\\", $password);
      ''}

      $config = array();
      $config['db_dsnw'] = 'pgsql://${cfg.database.username}${lib.optionalString (!localDB) ":' . $password . '"}@${if localDB then "unix(/run/postgresql)" else cfg.database.host}/${cfg.database.dbname}';
      $config['log_driver'] = 'syslog';
      $config['max_message_size'] =  '${cfg.maxAttachmentSize}';
      $config['plugins'] = [${concatMapStringsSep "," (p: "'${p}'") cfg.plugins}];
      $config['des_key'] = file_get_contents('/var/lib/roundcube/des_key');
      $config['mime_types'] = '${pkgs.nginx}/conf/mime.types';
      # Roundcube uses PHP-FPM which has `PrivateTmp = true;`
      $config['temp_dir'] = '/tmp';
      $config['enable_spellcheck'] = ${if cfg.dicts == [] then "false" else "true"};
      # by default, spellchecking uses a third-party cloud services
      $config['spellcheck_engine'] = 'pspell';
      $config['spellcheck_languages'] = array(${lib.concatMapStringsSep ", " (dict: let p = builtins.parseDrvName dict.shortName; in "'${p.name}' => '${dict.fullName}'") cfg.dicts});

      ${cfg.extraConfig}
    '';

    services.nginx = lib.mkIf cfg.configureNginx {
      enable = true;
      virtualHosts = {
        ${cfg.hostName} = {
          forceSSL = mkDefault true;
          enableACME = mkDefault true;
          root = cfg.package;
          locations."/" = {
            index = "index.php";
            priority = 1100;
            extraConfig = ''
              add_header Cache-Control 'public, max-age=604800, must-revalidate';
            '';
          };
          locations."~ ^/(SQL|bin|config|logs|temp|vendor)/" = {
            priority = 3110;
            extraConfig = ''
              return 404;
            '';
          };
          locations."~ ^/(CHANGELOG.md|INSTALL|LICENSE|README.md|SECURITY.md|UPGRADING|composer.json|composer.lock)" = {
            priority = 3120;
            extraConfig = ''
              return 404;
            '';
          };
          locations."~* \\.php(/|$)" = {
            priority = 3130;
            extraConfig = ''
              fastcgi_pass unix:${fpm.socket};
              fastcgi_param PATH_INFO $fastcgi_path_info;
              fastcgi_split_path_info ^(.+\.php)(/.+)$;
              include ${config.services.nginx.package}/conf/fastcgi.conf;
            '';
          };
        };
      };
    };

    assertions = [
      {
        assertion = localDB -> cfg.database.username == cfg.database.dbname;
        message = ''
          When setting up a DB and its owner user, the owner and the DB name must be
          equal!
        '';
      }
    ];

    services.postgresql = mkIf localDB {
      enable = true;
      ensureDatabases = [ cfg.database.dbname ];
      ensureUsers = [ {
        name = cfg.database.username;
        ensureDBOwnership = true;
      } ];
    };

    users.users.${user} = mkIf localDB {
      group = user;
      isSystemUser = true;
      createHome = false;
    };
    users.groups.${user} = mkIf localDB {};

    services.phpfpm.pools.roundcube = {
      user = if localDB then user else "nginx";
      phpOptions = ''
        error_log = 'stderr'
        log_errors = on
        post_max_size = ${cfg.maxAttachmentSize}
        upload_max_filesize = ${cfg.maxAttachmentSize}
      '';
      settings = mapAttrs (name: mkDefault) {
        "listen.owner" = "nginx";
        "listen.group" = "nginx";
        "listen.mode" = "0660";
        "pm" = "dynamic";
        "pm.max_children" = 75;
        "pm.start_servers" = 2;
        "pm.min_spare_servers" = 1;
        "pm.max_spare_servers" = 20;
        "pm.max_requests" = 500;
        "catch_workers_output" = true;
      };
      phpPackage = phpWithPspell;
      phpEnv.ASPELL_CONF = "dict-dir ${pkgs.aspellWithDicts (_: cfg.dicts)}/lib/aspell";
    };
    systemd.services.phpfpm-roundcube.after = [ "roundcube-setup.service" ];

    # Restart on config changes.
    systemd.services.phpfpm-roundcube.restartTriggers = [
      config.environment.etc."roundcube/config.inc.php".source
    ];

    systemd.services.roundcube-setup = mkMerge [
      (mkIf (cfg.database.host == "localhost") {
        requires = [ "postgresql.service" ];
        after = [ "postgresql.service" ];
        path = [ config.services.postgresql.package ];
      })
      {
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        script = let
          psql = "${lib.optionalString (!localDB) "PGPASSFILE=${cfg.database.passwordFile}"} ${pkgs.postgresql}/bin/psql ${lib.optionalString (!localDB) "-h ${cfg.database.host} -U ${cfg.database.username} "} ${cfg.database.dbname}";
        in
        ''
          version="$(${psql} -t <<< "select value from system where name = 'roundcube-version';" || true)"
          if ! (grep -E '[a-zA-Z0-9]' <<< "$version"); then
            ${psql} -f ${cfg.package}/SQL/postgres.initial.sql
          fi

          if [ ! -f /var/lib/roundcube/des_key ]; then
            base64 /dev/urandom | head -c 24 > /var/lib/roundcube/des_key;
            # we need to log out everyone in case change the des_key
            # from the default when upgrading from nixos 19.09
            ${psql} <<< 'TRUNCATE TABLE session;'
          fi

          ${phpWithPspell}/bin/php ${cfg.package}/bin/update.sh
        '';
        serviceConfig = {
          Type = "oneshot";
          StateDirectory = "roundcube";
          User = if localDB then user else "nginx";
          # so that the des_key is not world readable
          StateDirectoryMode = "0700";
        };
      }
    ];
  };
}
