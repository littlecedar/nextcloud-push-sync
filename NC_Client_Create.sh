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

arch=$(docker exec "$nc_name" uname -m)
case "$arch" in
  x86_64) bin=x86_64 ;;
  aarch64) bin=aarch64 ;;
  *) echo "unsupported $arch"; exit 1 ;;
esac
image=$(docker inspect "$nc_name" --format '{{.Config.Image}}')
nc_ip=$(docker inspect "$nc_name" --format '{{index .NetworkSettings.Networks "'"$traefik_net"'" "IPAddress"}}')
echo "nextcloud_traefik_ip=$nc_ip"

umask 077
envfile=$(mktemp)
trap 'rm -f "$envfile"' EXIT
docker inspect "$nc_name" --format '{{range .Config.Env}}{{println .}}{{end}}' > "$envfile"

docker create \
  --name "$push_name" \
  --init \
  --restart unless-stopped \
  --network "$postgres_net" \
  --env-file "$envfile" \
  --entrypoint "/var/www/html/custom_apps/notify_push/bin/${bin}/notify_push" \
  -e PORT=7867 \
  -e "NEXTCLOUD_URL=http://${nc_ip}" \
  -v "${nc_data}:/var/www/html:ro" \
  -v "${valkey_run}:/run-valkey" \
  --label traefik.enable=true \
  --label traefik.docker.network="$traefik_net" \
  --label "traefik.http.routers.${push_name}.entrypoints=web-secure" \
  --label "traefik.http.routers.${push_name}.rule=Host(\`${NEXTCLOUD_HOST}\`) && PathPrefix(\`/push\`)" \
  --label "traefik.http.routers.${push_name}.priority=1000" \
  --label "traefik.http.routers.${push_name}.tls=true" \
  --label "traefik.http.routers.${push_name}.tls.certResolver=default" \
  --label "traefik.http.routers.${push_name}.service=${push_name}" \
  --label "traefik.http.middlewares.${push_name}-strip.stripprefix.prefixes=/push" \
  --label "traefik.http.routers.${push_name}.middlewares=${push_name}-strip" \
  --label "traefik.http.services.${push_name}.loadbalancer.server.port=7867" \
  "$image" \
  /var/www/html/config/config.php

docker network connect "$traefik_net" "$push_name"
docker network connect "$nc_net" "$push_name"
docker network connect "$valkey_net" "$push_name"
docker start "$push_name"

sleep 3
docker logs --tail 20 "$push_name"

docker exec "$nc_name" sh -c 'if [ -d /var/www/html/custom_apps/context_chat/lib/Command ] && [ ! -d /var/www/html/custom_apps/context_chat/lib/Command.bak ]; then mv /var/www/html/custom_apps/context_chat/lib/Command /var/www/html/custom_apps/context_chat/lib/Command.bak; fi'
docker exec -w /var/www/html "$nc_name" php /var/www/html/occ notify_push:setup "https://${NEXTCLOUD_HOST}/push"
docker exec -w /var/www/html "$nc_name" php /var/www/html/occ notify_push:self-test
docker exec "$nc_name" sh -c 'if [ -d /var/www/html/custom_apps/context_chat/lib/Command.bak ]; then mv /var/www/html/custom_apps/context_chat/lib/Command.bak /var/www/html/custom_apps/context_chat/lib/Command; fi'
