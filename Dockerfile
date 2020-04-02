FROM centos:centos8

# 日本語・日本時間
RUN dnf -y install langpacks-ja glibc-locale-source glibc-langpack-en; dnf clean all;
RUN localedef -f UTF-8 -i ja_JP ja_JP.UTF-8
ENV LANG="ja_JP.UTF-8" \
  LANGUAGE="ja_JP:ja" \
  LC_ALL="ja_JP.UTF-8" \
  TIMEZONE="Asia/Tokyo"
RUN localedef -f UTF-8 -i ja_JP ja_JP.UTF-8 && \
  echo 'LANG="ja_JP.UTF-8"' >  /etc/locale.conf && \
  echo 'ZONE="Asia/Tokyo"' > /etc/sysconfig/clock && \
  unlink /etc/localtime && \
  ln -s /usr/share/zoneinfo/Japan /etc/localtime

# certificate
RUN mkdir /cert; \
  dnf -y install openssl; \
  openssl genrsa -aes256 -passout pass:dummy -out "/cert/key.pass.pem" 4096; \
  openssl rsa -passin pass:dummy -in "/cert/key.pass.pem" -out "/cert/key.pem"; \
  rm -f /cert/key.pass.pem; \
  dnf clean all;

# rsyslog
RUN dnf -y install rsyslog; \
  sed -i 's/\(SysSock\.Use\)="off"/\1="on"/' /etc/rsyslog.conf; \
  dnf clean all;

# supervisor
RUN mkdir /run/supervisor; \
  dnf -y install epel-release; \
  dnf -y install supervisor; \
  sed -i 's/^\(nodaemon\)=false/\1=true/' /etc/supervisord.conf; \
  sed -i 's/^;\(user\)=chrism/\1=root/' /etc/supervisord.conf; \
  sed -i '/^\[unix_http_server\]$/a username=dummy\npassword=dummy' /etc/supervisord.conf; \
  sed -i '/^\[supervisorctl\]$/a username=dummy\npassword=dummy' /etc/supervisord.conf; \
  { \
  echo '[program:postfix]'; \
  echo 'command=/usr/sbin/postfix -c /etc/postfix start'; \
  echo 'priority=3'; \
  echo 'startsecs=0'; \
  } > /etc/supervisord.d/postfix.ini; \
  { \
  echo '[program:rsyslog]'; \
  echo 'command=/usr/sbin/rsyslogd -n'; \
  echo 'priority=2'; \
  } > /etc/supervisord.d/rsyslog.ini; \
  { \
  echo '[program:tail]'; \
  echo 'command=/usr/bin/tail -F /var/log/maillog'; \
  echo 'priority=1'; \
  echo 'stdout_logfile=/dev/fd/1'; \
  echo 'stdout_logfile_maxbytes=0'; \
  } > /etc/supervisord.d/tail.ini; \
  dnf clean all;

# postfix
RUN dnf -y install postfix cyrus-sasl-plain cyrus-sasl-md5; \
  dnf clean all;
RUN sed -i 's/^\(inet_interfaces =\) .*/\1 all/' /etc/postfix/main.cf; \
  sed -i 's/^\(smtpd_tls_cert_file =\) .*/\1 \/cert\/cert.pem/' /etc/postfix/main.cf; \
  sed -i 's/^\(smtpd_tls_key_file =\) .*/\1 \/cert\/key.pem/' /etc/postfix/main.cf; \
  { \
  echo 'smtpd_sasl_path = smtpd'; \
  echo 'smtpd_sasl_auth_enable = yes'; \
  echo 'broken_sasl_auth_clients = yes'; \
  echo 'smtpd_sasl_security_options = noanonymous'; \
  echo 'disable_vrfy_command = yes'; \
  echo 'smtpd_helo_required = yes'; \
  echo 'smtpd_helo_restrictions = permit_mynetworks, permit_sasl_authenticated, reject_invalid_hostname, reject_non_fqdn_hostname, reject_unknown_hostname'; \
  echo 'smtpd_recipient_restrictions = permit_mynetworks,permit_sasl_authenticated, reject_unauth_destination'; \
  echo 'smtpd_sender_restrictions = reject_non_fqdn_sender, reject_unknown_sender_domain'; \
  echo 'smtpd_tls_security_level = may'; \
  echo 'smtpd_tls_received_header = yes'; \
  echo 'smtpd_tls_loglevel = 1'; \
  echo 'smtp_tls_security_level = may'; \
  echo 'smtp_tls_loglevel = 1'; \
  echo 'mynetworks = 127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16'; \
  echo 'smtp_tls_session_cache_database = btree:${data_directory}/smtp_scache'; \
  echo 'tls_random_source = dev:/dev/urandom'; \
  } >> /etc/postfix/main.cf; \
  { \
  echo 'pwcheck_method: auxprop'; \
  echo 'auxprop_plugin: sasldb'; \
  echo 'mech_list: PLAIN LOGIN CRAM-MD5 DIGEST-MD5'; \
  } > /etc/sasl2/smtpd.conf; \
  sed -i 's/^#\(submission .*\)/\1/' /etc/postfix/master.cf; \
  sed -i 's/^#\(smtps .*\)/\1/' /etc/postfix/master.cf; \
  sed -i 's/^#\(.* syslog_name=.*\)/\1/' /etc/postfix/master.cf; \
  sed -i 's/^#\(.* smtpd_sasl_auth_enable=.*\)/\1/' /etc/postfix/master.cf; \
  sed -i 's/^#\(.* smtpd_recipient_restrictions=.*\)/\1/' /etc/postfix/master.cf; \
  sed -i 's/^#\(.* smtpd_tls_wrappermode=.*\)/\1/' /etc/postfix/master.cf; \
  newaliases;

# entrypoint
RUN { \
  echo '#!/bin/bash -eu'; \
  echo 'ln -fs /usr/share/zoneinfo/${TIMEZONE} /etc/localtime'; \
  echo 'rm -f /var/log/maillog'; \
  echo 'touch /var/log/maillog'; \
  echo 'openssl req -new -sha384 -key "/cert/key.pem" -subj "/CN=${HOST_NAME}" -out "/cert/csr.pem"'; \
  echo 'openssl x509 -req -days 36500 -in "/cert/csr.pem" -signkey "/cert/key.pem" -out "/cert/cert.pem" &>/dev/null'; \
  echo 'if [ -e /etc/sasldb2 ]; then'; \
  echo '  rm -f /etc/sasldb2'; \
  echo 'fi'; \
  echo 'sed -i "s/^\(smtpd_sasl_auth_enable =\).*/\1 yes/" /etc/postfix/main.cf'; \
  echo 'if [ ${DISABLE_SMTP_AUTH_ON_PORT_25,,} = "true" ]; then'; \
  echo '  sed -i "s/^\(smtpd_sasl_auth_enable =\).*/\1 no/" /etc/postfix/main.cf'; \
  echo 'fi'; \
  echo 'echo "${AUTH_PASSWORD}" | /usr/sbin/saslpasswd2 -p -c -u ${DOMAIN_NAME} ${AUTH_USER}'; \
  echo 'chown postfix:postfix /etc/sasldb2'; \
  echo 'sed -i '\''/^# BEGIN SMTP SETTINGS$/,/^# END SMTP SETTINGS$/d'\'' /etc/postfix/main.cf'; \
  echo '{'; \
  echo 'echo "# BEGIN SMTP SETTINGS"'; \
  echo 'echo "myhostname = ${HOST_NAME}"'; \
  echo 'echo "mydomain = ${DOMAIN_NAME}"'; \
  echo 'echo "smtpd_banner = \$myhostname ESMTP unknown"'; \
  echo 'echo "message_size_limit = ${MESSAGE_SIZE_LIMIT}"'; \
  echo 'echo "# END SMTP SETTINGS"'; \
  echo '} >> /etc/postfix/main.cf'; \
  echo 'exec "$@"'; \
  } > /usr/local/bin/entrypoint.sh; \
  chmod +x /usr/local/bin/entrypoint.sh;

ARG hostname="smtp.example.com"
ENV HOST_NAME $hostname

ARG domain_name="example.com"
ENV DOMAIN_NAME $domain_name

ENV MESSAGE_SIZE_LIMIT 10240000

ARG auth_user="user"
ENV AUTH_USER $auth_user
ARG auth_password="password"
ENV AUTH_PASSWORD $auth_password

ARG disable_smtp_auth_on_port_25="true"
ENV DISABLE_SMTP_AUTH_ON_PORT_25 $disable_smtp_auth_on_port_25

# SMTP
EXPOSE 25
# Submission
EXPOSE 587
# SMTPS
EXPOSE 465

ENTRYPOINT ["entrypoint.sh"]
CMD ["supervisord", "-c", "/etc/supervisord.conf"]
