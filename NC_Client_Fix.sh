#!/bin/sh
set -eu
: "${NEXTCLOUD_HOST:?Set NEXTCLOUD_HOST to the public Nextcloud hostname}"

nc_name=${NC_CONTAINER:-mash-nextcloud-server}
push_name=${PUSH_CONTAINER:-mash-nextcloud-push}
nc_data=${NC_DATA:-/mash/nextcloud/data}
valkey_run=${VALKEY_RUN:-/mash/nextcloud-valkey/run}
traefik_net=${TRAEFIK_NETWORK:-traefik}
postgres_net=${POSTGRES_NETWORK:-mash-postgres}
nc_net=${NC_NETWORK:-mash-nextcloud}
valkey_net=${VALKEY_NETWORK:-mash-nextcloud-valkey}
nc_service=${NC_SERVICE:-mash-nextcloud-server.service}

sudo tee /etc/nextcloud-push-sync.env >/dev/null << EOF
NEXTCLOUD_HOST=${NEXTCLOUD_HOST}
NC_CONTAINER=${nc_name}
PUSH_CONTAINER=${push_name}
NC_DATA=${nc_data}
VALKEY_RUN=${valkey_run}
TRAEFIK_NETWORK=${traefik_net}
POSTGRES_NETWORK=${postgres_net}
NC_NETWORK=${nc_net}
VALKEY_NETWORK=${valkey_net}
EOF
sudo chmod 644 /etc/nextcloud-push-sync.env

sudo tee /usr/local/sbin/nextcloud-push-sync >/dev/null << 'EOF'
#!/bin/sh
set -eu
. /etc/nextcloud-push-sync.env
: "${NEXTCLOUD_HOST:?NEXTCLOUD_HOST is missing from /etc/nextcloud-push-sync.env}"

nc_name=$NC_CONTAINER
push_name=$PUSH_CONTAINER
nc_data=$NC_DATA
valkey_run=$VALKEY_RUN
traefik_net=$TRAEFIK_NETWORK
postgres_net=$POSTGRES_NETWORK
nc_net=$NC_NETWORK
valkey_net=$VALKEY_NETWORK

nc_ip=
i=0
while [ "$i" -lt 30 ]; do
  nc_ip=$(docker inspect "$nc_name" --format '{{range $n,$c := .NetworkSettings.Networks}}{{if eq $n "'"$traefik_net"'}}{{$c.IPAddress}}{{end}}{{end}}' 2>/dev/null || true)
  if [ -n "$nc_ip" ]; then
    break
  fi
  i=$((i + 1))
  sleep 2
done
[ -n "$nc_ip" ]
echo "nextcloud_traefik_ip=$nc_ip"

docker exec "$nc_name" sh -c 'if [ -d /var/www/html/custom_apps/context_chat/lib/Command ] && [ ! -d /var/www/html/custom_apps/context_chat/lib/Command.bak ]; then mv /var/www/html/custom_apps/context_chat/lib/Command /var/www/html/custom_apps/context_chat/lib/Command.bak; fi'
docker exec -w /var/www/html "$nc_name" php /var/www/html/occ config:system:set trusted_domains 1 --value="$nc_ip"
docker exec "$nc_name" sh -c 'if [ -d /var/www/html/custom_apps/context_chat/lib/Command.bak ]; then mv /var/www/html/custom_apps/context_chat/lib/Command.bak /var/www/html/custom_apps/context_chat/lib/Command; fi'

current=$(docker inspect "$push_name" --format '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' | sed -n 's|^NEXTCLOUD_URL=http://||p')
if [ "$current" = "$nc_ip" ]; then
  echo "push URL already matches"
  exit 0
fi

arch=$(docker exec "$nc_name" uname -m)
case "$arch" in
  x86_64) bin=x86_64 ;;
  aarch64) bin=aarch64 ;;
  *) echo "unsupported $arch"; exit 1 ;;
esac
image=$(docker inspect "$push_name" --format '{{.Config.Image}}')
umask 077
envfile=$(mktemp)
trap 'rm -f "$envfile"' EXIT
docker inspect "$push_name" --format '{{range .Config.Env}}{{printf "%s\n" .}}{{end}}' | grep -v '^NEXTCLOUD_URL=' > "$envfile"
printf 'NEXTCLOUD_URL=http://%s\n' "$nc_ip" >> "$envfile"
docker stop "$push_name"
docker rm "$push_name"
docker create --name "$push_name" --init --restart unless-stopped \
  --network "$postgres_net" \
  --env-file "$envfile" \
  --entrypoint "/var/www/html/custom_apps/notify_push/bin/${bin}/notify_push" \
  -v "${nc_data}:/var/www/html:ro" \
  -v "${valkey_run}:/run-valkey" \
  --label traefik.enable=true \
  --label traefik.docker.network="$traefik_net" \
  --label "traefik.http.routers.${push_name}.rule=Host(\`${NEXTCLOUD_HOST}\`) && PathPrefix(\`/push\`)" \
  --label "traefik.http.routers.${push_name}.entrypoints=web-secure" \
  --label "traefik.http.routers.${push_name}.tls=true" \
  --label "traefik.http.routers.${push_name}.tls.certResolver=default" \
  --label "traefik.http.routers.${push_name}.priority=1000" \
  --label "traefik.http.routers.${push_name}.middlewares=${push_name}-strip" \
  --label "traefik.http.routers.${push_name}.service=${push_name}" \
  --label "traefik.http.middlewares.${push_name}-strip.stripprefix.prefixes=/push" \
  --label "traefik.http.services.${push_name}.loadbalancer.server.port=7867" \
  "$image" \
  /var/www/html/config/config.php
docker network connect "$traefik_net" "$push_name"
docker network connect "$nc_net" "$push_name"
docker network connect "$valkey_net" "$push_name"
docker start "$push_name"
echo "push URL updated"
EOF
sudo chmod 755 /usr/local/sbin/nextcloud-push-sync

sudo tee /etc/systemd/system/nextcloud-push-sync.service >/dev/null << EOF
[Unit]
Description=Point Nextcloud push at the current Nextcloud address
After=docker.service ${nc_service}
Requires=${nc_service}
PartOf=${nc_service}

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nextcloud-push-sync

[Install]
WantedBy=${nc_service}
EOF
sudo systemctl daemon-reload
sudo systemctl enable nextcloud-push-sync.service
sudo systemctl start nextcloud-push-sync.service
systemctl status nextcloud-push-sync.service --no-pager
