#!/bin/bash

(cd portus && docker build -t portus-base . )
(cd registry && docker build -t portus-registry . )
(cd nginx && docker build -t portus-nginx . )

sleep 5
set -e

check_version() {
	VER=$(docker-compose version --short)
	if [ "$VER" = "1.5.1" ]; then
		# Known to have bugs when generating configs.
cat >&2 <<EOF
Your docker-compose version is known to have bugs that make Portus unusable. The
known affected version(s) are:
  - 1.5.1
Updating or downgrading to any other version will solve this issue. The file
docker/registry/config.yml will also be deleted (as any configuration files
generated by the above versions of docker-compose need to be replaced).
EOF
		if [ "$FORCE" -ne 1 ]; then
			rm -f "registry/config.yml"
			exit 1
		else
			echo "Ignoring docker-compose version since -f was given." >&2
		fi
	fi
}

setup_database() {
  set +e

  TIMEOUT=90
  COUNT=0
  RETRY=1

  while [ $RETRY -ne 0 ]; do
    if [ "$COUNT" -ge "$TIMEOUT" ]; then
      printf " [FAIL]\n"
      echo "Timeout reached, exiting with error"
      exit 1
    fi
    echo "Waiting for mariadb to be ready in 5 seconds"
    sleep 5
    COUNT=$((COUNT+5))

    printf "Portus: configuring database..."
    docker-compose run --rm portus-migrate
    RETRY=$?
    if [ $RETRY -ne 0 ]; then
        printf " failed, will retry\n"
    fi
  done
  printf " [SUCCESS]\n"
  set -e
}


clean() {
  echo "The setup will destroy the containers used by Portus, removing also their volumes."
  if [ $FORCE -ne 1 ]; then
    while true; do
      read -p "Are you sure to delete all the data? (Y/N) " yn
      case $yn in
        [Yy]* )
          break;;
        [Nn]* ) exit 1;;
        * ) echo "Please answer yes or no.";;
      esac
    done
  fi

  docker-compose kill
  docker-compose rm portus-nginx portus-web portus-crono portus-registry
  #docker-compose rm -fv
}

usage() {
  echo "Usage: $0 [-f]"
  echo "  -f force removal of data"
}

# Force the current directory to be named "portus". It's known that other
# setups will make docker-compose fail.
#
# See: https://github.com/docker/compose/issues/2092
# if [ "${PWD##*/}" != "portus" ] && [ "${PWD##*/}" != "Portus" ]; then
#     cat <<HERE
# ERROR: docker-compose is not able to tag built images. Since our compose setup
# expects the built image be named "portus_web", the current directory has to be
# named "portus" in order to work.
# HERE
#     exit 1
# fi

if [ -z $DOCKER_HOST ]; then
  # Get the docker host by picking the IP from the docker0 interface. This is the
  # safest way to reference the Docker host (see issues #417 and #382).
  DOCKER_HOST=$(/sbin/ifconfig docker0 | grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}' | head -1)
fi
echo "DOCKER_HOST=${DOCKER_HOST}" > registry/environment

FORCE=0
while getopts "fh" opt; do
  case "${opt}" in
    f)
      FORCE=1
      ;;
    h)
      usage
      exit 0
      ;;
    *)
      echo "Invalid option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done

check_version
# y/n prompt
cat <<EOM

#######################
# REMOVING CONTAINERS #
#######################

EOM

clean

cat <<EOM

#######################
#   RUNNING COMPOSE   #
#######################

EOM


docker-compose up -d

# setup_database

# At this point, the DB is up and running. Therefore, at this point the crono
# container will certainly work.
docker-compose restart portus-crono

# The cleaned up host. We do this because when the $DOCKER_HOST variable was
# already set, then it might come with the port included.
final_host=$(echo $DOCKER_HOST | grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}' | head -1)

cat <<EOM

###################
#     SUCCESS     #
###################

EOM

echo "Make sure you open port 80 and 443 on the final host"
printf "\n"

echo "Open https://portus.yourdomain.com with your browser and perform the following steps:"
printf "\n"
echo "  1. Create an admin account"
echo "  2. You will be redirected to a page where you have to register the registry. In this form:"
echo "    - Choose a custom name for the registry."
echo "    - Enter https://docker.yourdomain.com as the hostname."
echo "    - DO CHECK SSL - because this setup is designed for SSL
printf "\n"

printf "\n"
echo "To authenticate against your registry using the docker cli do:"
printf "\n"
echo "  $ docker login -u <portus username> -p <password> -e <email> docker.yourdomain.com"
printf "\n"

echo "To push an image to the private registry:"
printf "\n"
echo "  $ docker pull busybox"
echo "  $ docker tag busybox docker.yourdomain.com/<username>busybox"
echo "  $ docker push docker.yourdomain.com/<username>busybox"
