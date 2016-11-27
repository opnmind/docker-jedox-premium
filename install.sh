#!/bin/bash
#
# Author: Jerome Meinke, Jedox AG, Freiburg
# Author: Christoffer Anselm, Jedox AG, Freiburg
#
# Installation script for the Jedox Suite 5.1
#
SILENT_INSTALL=true
USE_TLS=y
VER_MAJOR=5
VER_MINOR=1
VERSION="$VER_MAJOR.$VER_MINOR"

###############################################################################
## Definition of default values - changing this might break this script.
###############################################################################

TAB=$'\t'
CURRENT_PATH=$(pwd)
INSTALL_PACKAGE=./jedox_ps.tar.gz
INSTALL_PATH=/opt/jedox/ps
DIR_NAME_STORAGE=storage
DIR_NAME_DATA=Data
ETL_DATA_PACKAGE=etl-data
ETL_DATA_PATH=tomcat/webapps/etlserver/data/
IS_UPGRADE=false
DATA_REPLACED=false

###############################################################################
## Standard host and port variables. Their values are used in questions
## and can be altered in an upgrade installation. During the installation
## process these values are written to new configuration files.
###############################################################################

# hosts
HOST_OLAP="\"\"" # all interfaces
HOST_HTTP="" # all interfaces
HOST_SSS="127.0.0.1"
HOST_TC_AJP="127.0.0.1"
HOST_TC_HTTP="127.0.0.1"

# ports
PORT_OLAP=7777
PORT_HTTP=80
PORT_SSS=8193
PORT_TC_AJP=8010
PORT_TC_HTTP=7775
PORT_TLS=443

###############################################################################
## Jedox Suite standard user and standard group
###############################################################################

JEDOX_USER=jedoxweb
JEDOX_GROUP=jedoxweb

###############################################################################
## Definition of methods/functions used by the installation routine:
###############################################################################

COMMAND_EXISTS() {
  command -v "$1" >/dev/null 2>&1
  return $?
}

CHROOT_ENABLED() {
  chroot / /bin/bash -c "exit" >/dev/null 2>&1
  return $?
}

STR_TO_HEX() {
  od -An -txC | tr -d ' ' | tr -d '\012'
}

HEX_TO_STR() {
  local saveIFS saveLANG char
  
  saveIFS="$IFS"
  IFS=""                     # disables interpretation of \t, \n and space
  saveLANG="$LANG"
  LANG=C                     # allows characters > 0x7F
  
  while read -s -n 2 char
  do
    #printf "\x%s" "$char"
		printf "\x$char"
  done
  
  LANG="$saveLANG";
  IFS="$saveIFS"
}

USERID_BY_NAME() {
  id -u "$1"
}

GROUPID_BY_NAME() {
  getent group "$1" | cut -d: -f3
}

# Test host:port availability
TCP_FREE() {
  # 1: hostname
  # 2: port
  (timeout 1 bash -c "echo >/dev/tcp/$1/$2") &>/dev/null
  if [ $? -eq 0 ]; then
    return 1
  else
    return 0
  fi
}

PORT_INFO() {
  # 1: hostname
  # 2: port
  echo -n "$1:$2 "
  if TCP_FREE "$1" "$2"; then
    echo "[$(tput setaf 2; tput bold)OK$(tput sgr 0)]"
  else
    echo "[$(tput setaf 1)USED$(tput sgr 0)]"
  fi
}

DIR_IS_EMPTY() {
  # Checks if the specified directory contains nonhidden files.
  for FILE in $1/*; do
    if [ -e "$FILE" ]; then
      return 1
    fi
  done
  return 0
}

###############################################################################
## Functions for reading and writing settings to the config.php file
###############################################################################

PHP_CFG_GET_VALUE() {
  # $1 = config.php file path
  # $2 = key
  
  local php_cfg key value
  
  php_cfg="$1"
  key="$2"
  value=$( sed -n "s/^define('${key}',\s*'\?\([^']*\)'\?);$/\1/p" "$php_cfg" )
  echo -n "$value"
}

PHP_CFG_SET_VALUE() {
  # $1 = config.php file path
  # $2 = key
  # $3 = new value
  
  local php_cfg key new_value key_sedl key_sedr new_value_sedr
  
  php_cfg="$1"
  key="$2"
  new_value="$3"
  
  # escape '[\/.*|]'
  key_sedl="$( echo -n "${key}" | sed 's/\([[\/.*]\|\]\)/\\&/g' )"
  # escape '\/&'
  key_sedr="$( echo -n "${key}" | sed 's/[\/&]/\\&/g' )"
  new_value_sedr="$( echo -n "${new_value}" | sed 's/[\/&]/\\&/g' )"
  
  if [ -z "$( grep "'${key}'" "${php_cfg}" )" ]; then
    if [ -z "$( grep "?>" "$php_cfg" )" ]; then
      echo "define('${key}', ${new_value});" >> "$php_cfg"
    else
      sed -i "s/?>/define('${key_sedr}', ${new_value_sedr});\n?>/g;" "${php_cfg}"
    fi
  else
    sed -i "s/\(define\s*(\s*'${key_sedl}'\s*,\s*\).*\()\s*;\)/\1${new_value_sedr}\2/g;" "${php_cfg}"
  fi
	return $?
}

PHP_CFG_NEW_VALUE() {
  # $1 = config.php file path
  # $2 = key
  # $3 = new value
  # $4 = comment
  
  local php_cfg key new_value key_sedr new_value_sedr comment
  
  php_cfg="$1"
  key="$2"
  new_value="$3"
  comment="$4"
  
  # escape '\/&'
  key_sedr="$( echo -n "${key}" | sed 's/[\/&]/\\&/g' )"
  new_value_sedr="$( echo -n "${new_value}" | sed 's/[\/&]/\\&/g' )"
  comment_sedr="$( echo -n "${comment}" | sed 's/[\/&]/\\&/g' )"
  
  if [ -z "$( grep "'${key}'" "${php_cfg}" )" ]; then
    if [ -z "$( grep "?>" "$php_cfg" )" ]; then
      echo "define('${key}', ${new_value});" >> "$php_cfg"
    else
      sed -i "s/?>/\n${comment_sedr}\n?>/g;" "${php_cfg}"
      sed -i "s/?>/define('${key_sedr}', ${new_value_sedr});\n?>/g;" "${php_cfg}"
    fi
  fi
	return $?
}

PHP_CFG_REPLACE_VALUE() {
  # $1 = config.php file path
  # $2 = key
  # $3 = old value
  # $4 = new value
  
  local php_cfg key old_value new_value key_sedl key_sedr old_value_sedl new_value_sedr
  
  php_cfg="$1"
  key="$2"
  old_value="$3"
  new_value="$4"
  
  # escape '[\/.*|]'
  key_sedl="$( echo -n "${key}" | sed 's/\([[\/.*]\|\]\)/\\&/g' )"
  old_value_sedl="$( echo -n "${old_value}" | sed 's/\([[\/.*]\|\]\)/\\&/g' )"
  # escape '\/&'
  key_sedr="$( echo -n "${key}" | sed 's/[\/&]/\\&/g' )"
  new_value_sedr="$( echo -n "${new_value}" | sed 's/[\/&]/\\&/g' )"
  
  if [ -z "$( grep "'${key}'" "${php_cfg}" )" ]; then
    if [ -z "$( grep "?>" "$php_cfg" )" ]; then
      echo "define('${key}', ${new_value});" >> "$php_cfg"
    else
      sed -i "s/?>/define('${key_sedr}', ${new_value_sedr});\n?>/g;" "${php_cfg}"
    fi
  else
    sed -i "s/\(define\s*(\s*'${key_sedl}'\s*,\s*\)${old_value_sedl}\(\s*)\s*;\)/\1${new_value_sedr}\2/g;" "${php_cfg}"
  fi
	return $?
}

PUT_CFG_PALO_PASS() {
  #  only works with untar'ed jail!
  #
  # $1 = config.php file path
  # $2 = secret
  # $3 = plain password
  
  local outfile key pass hex_iv hex_key hex_enc_pass full_pass
  
  outfile="$1"
  key="$2"
  pass="$3"
  
  hex_iv="$( head -c 500 /dev/urandom | tr -dc a-z0-9A-Z | tr -d ' ' | tr -d '\t' | tr -d '/' | head -c 16 | STR_TO_HEX )"
  hex_key="$( echo -n "$key" | STR_TO_HEX )"
  
  # OPENSSL_CONF=/etc/pki/tls/openssl.cnf is needed, because we provide our own openssl library in the jail (but we use openssl.cnf from CentOS)
  hex_enc_pass="$( echo -n "$pass" | chroot "$INSTALL_PATH" env OPENSSL_CONF=/etc/pki/tls/openssl.cnf openssl enc -aes-128-cfb8 -K "$hex_key" -iv "$hex_iv" | STR_TO_HEX )"
  
  full_pass=$'\t'"a"$'\t'"$( echo -n "$hex_iv$hex_enc_pass" | HEX_TO_STR | chroot "$INSTALL_PATH" base64 )"
  
  PHP_CFG_SET_VALUE "$outfile" "CFG_PALO_PASS" "'$full_pass'"
}

###############################################################################
## Functions for retrieving/setting host and port in palo.ini
###############################################################################

# palo.ini host and port detection
R_START="^http[[:blank:]]\+"
R_EMPTY="\"\""
R_DOMAIN="\(\([a-zA-Z0-9]\|[a-zA-Z0-9][a-zA-Z0-9\-]\{0,61\}[a-zA-Z0-9]\)\(\.\([a-zA-Z0-9]\|[a-zA-Z0-9][a-zA-Z0-9\-]\{0,61\}[a-zA-Z0-9]\)\)*\)" # 4 match groups -> \2 \3 \4 \5
#R_DOMAIN="\([a-zA-Z0-9]\|[a-zA-Z0-9][a-zA-Z0-9\-]\{0,61\}[a-zA-Z0-9]\)\(\.\([a-zA-Z0-9]\|[a-zA-Z0-9][a-zA-Z0-9\-]\{0,61\}[a-zA-Z0-9]\)\)*" 
R_IP="\(\([0-9]\|[1-9][0-9]\|1[0-9]\{2\}\|2[0-4][0-9]\|25[0-5]\)\.\)\{3\}\([0-9]\|[1-9][0-9]\|1[0-9]\{2\}\|2[0-4][0-9]\|25[0-5]\)" # 3 match groups -> \6 \7 \8
R_HOST="\($R_EMPTY\|$R_DOMAIN\|$R_IP\)" # 1 group -> host \1
R_SEP="[[:blank:]]\+"
R_PORT="\([0-9]\{1,6\}\)" # 1 group -> port \9

OLAP_R_HOST="s/$R_START$R_HOST$R_SEP$R_PORT/\1/p"
OLAP_R_PORT="s/$R_START$R_HOST$R_SEP$R_PORT/\9/p"

GET_OLAP_HOST() {
	# 1: path to palo.ini
	# return OLAP host, or 0 if palo.ini not found
	local curr paloini

	paloini=$1
	if [ ! -f "$paloini" ]; then
		return 0
	fi

	curr=$(sed -n "$OLAP_R_HOST" "$paloini")
	echo -n "$curr"
}

GET_OLAP_PORT() {
	# 1: path to palo.ini
	# return OLAP port, or 0 if palo.ini not found
	local curr paloini

	paloini=$1
	if [ ! -f "$paloini" ]; then
		return 0
	fi

	curr=$(sed -n "$OLAP_R_PORT" "$paloini")
	if [ -z "$curr" ]; then
		# should never be empty
		return 0
	fi
	echo -n "$curr"
}

SET_OLAP() {
	# 1: path to palo.ini
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port paloini

	paloini=$1
	if [ ! -f "$paloini" ]; then
		return 1
	fi
	host=$2
	port=$3

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "s/$R_START$R_HOST$R_SEP$R_PORT/http$TAB$host$TAB$port/g" "$paloini"
	elif [ ! -z "$host" ]; then
		sed -i.bak "s/$R_START$R_HOST$R_SEP$R_PORT/http$TAB$host$TAB\9/g" "$paloini"
	elif [ ! -z "$port" ]; then
		sed -i.bak "s/$R_START$R_HOST$R_SEP$R_PORT/http$TAB\1$TAB$port/g" "$paloini"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting host and port in palo_config.xml
###############################################################################

GET_SSS_OLAP_HOST() {
	# 1: path to palo_config.xml
	# return host, or 0 if palo_config.xml not found
	local curr paloconfigxml

	paloconfigxml=$1
	if [ ! -f "$paloconfigxml" ]; then
		return ""
	fi

	curr=$(grep -o '<host[^>].* \/>' "$paloconfigxml" | sed 's/.*"\(.*\)"[^"]*$/\1/')
  if [ -z "$curr" ]; then
    curr=$(grep -o '<host>.*</host>' "$paloconfigxml" | sed -e 's,.*<host>\([^<]*\)</host>.*,\1,g')
  fi
	echo -n "$curr"
}

GET_SSS_OLAP_PORT() {
	# 1: path to palo_config.xml
	# return port, or 0 if palo_config.xml not found
	local curr paloconfigxml
	
	paloconfigxml=$1
	if [ ! -f "$paloconfigxml" ]; then
		return 0
	fi

	curr=$(grep -o '<port[^>].* \/>' "$paloconfigxml" | sed 's/.*"\(.*\)"[^"]*$/\1/')
  if [ -z "$curr" ]; then
    curr=$(grep -o '<port>[0-9]*</port>' "$paloconfigxml" | grep -Po '\d+')
  fi
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_SSS_OLAP() {
	# 1: path to palo_config.xml
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port paloini

	paloconfigxml=$1
	if [ ! -f "$paloconfigxml" ]; then
		return 1
	fi
	host=$2
	port=$3

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "s/<host>\([^<]*\)<\/host>/<host>$host<\/host>/g; s/<port>\([^<]*\)<\/port>/<port>$port<\/port>/g" "$paloconfigxml"
	elif [ ! -z "$host" ]; then
		sed -i.bak "s/<host>\([^<]*\)<\/host>/<host>$host<\/host>/g" "$paloconfigxml"
	elif [ ! -z "$port" ]; then
		sed -i.bak "s/<port>\([^<]*\)<\/port>/<port>$port<\/port>/g" "$paloconfigxml"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting host and port in ui_backend_config.xml
###############################################################################

GET_SSS_HOST() {
	# 1: path to ui_backend_config.xml
	# return host, or 0 if ui_backend_config.xml not found
	local curr uibackendxml

	uibackendxml=$1
	if [ ! -f "$uibackendxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<tcp.*address=\"\([^\"]*\)\".*$/\1/p" "$uibackendxml")
	if [ -z "$curr" ]; then
		curr="\"\""
	fi
	echo -n "$curr"
}

GET_SSS_PORT() {
	# 1: path to ui_backend_config.xml
	# return port, or 0 if ui_backend_config.xml not found
	local curr uibackendxml

	uibackendxml=$1
	if [ ! -f "$uibackendxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<tcp.*port=\"\([0-9]*\)\".*$/\1/p" "$uibackendxml")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_SSS() {
	# 1: path to ui_backend_config.xml
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port uibackendxml regex_host regex_port

	uibackendxml=$1
	if [ ! -f "$uibackendxml" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^\([[:blank:]]\+\)<tcp\(.*\)address=\"\([^\"]*\)\"\(.*\)$/\1<tcp\2address=\"$host\"\4/g"
	regex_port="s/^\([[:blank:]]\+\)<tcp\(.*\)port=\"\([0-9]*\)\"\(.*\)$/\1<tcp\2port=\"$port\"\4/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$uibackendxml"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$uibackendxml"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$uibackendxml"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting host and port in svs-Linux-i686/php.ini
###############################################################################

GET_SVS_HOST() {
	# 1: path to svs-Linux-i686/php.ini
	# return host, or 0 if php.ini not found
	local curr phpini

	phpini=$1
	if [ ! -f "$phpini" ]; then
		return ""
	fi

	curr=$(sed -n "s/^palo_server_hostname=\([^ ]*\)$/\1/p" "$phpini")
	if [ -z "$curr" ]; then
		return "127.0.0.1"
	fi
	echo -n "$curr"
}

GET_SVS_PORT() {
	# 1: path to svs-Linux-i686/php.ini
	# return port, or 0 if php.ini not found
	local curr phpini

	phpini=$1
	if [ ! -f "$phpini" ]; then
		return 0
	fi

	#curr=$(grep -o 'palo_server_port=[0-9]*' "$phpini" | grep -Po '\d+')
	curr=$(sed -n "s/^palo_server_port=\([0-9]*\)$/\1/p" "$phpini")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_SVS() {
	# 1: path to svs-Linux-i686/php.ini
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local phpini host port regex_host regex_port

	phpini=$1
	if [ ! -f "$phpini" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^palo_server_hostname=\([^ ]*\)$/palo_server_hostname=$host/g"
	regex_port="s/^palo_server_port=\([0-9]*\)$/palo_server_port=$port/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$phpini"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$phpini"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$phpini"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting port in httpd.conf
###############################################################################

GET_HTTPD_HOST() {
	# 1: path to httpd.conf
	# return host, or 0 if httpd.conf not found
	local curr httpdconf

	httpdconf=$1
	if [ ! -f "$httpdconf" ]; then
		return 0
	fi

	curr=( $(sed -n "s/^Listen[[:blank:]]\+\(.*\):\([0-9]*\)/\1/p" "$httpdconf") )
	for i in "${curr[@]}"; do
		if [ "$i" != "127.0.0.1" ] && [ "$i" != "localhost" ]; then
			echo -n "$i"
			break
		fi
	done
}

GET_HTTPD_PORT() {
	# 1: path to httpd.conf
	# return port, or 0 if httpd.conf not found
	local curr httpdconf

	httpdconf=$1
	if [ ! -f "$httpdconf" ]; then
		return 0
	fi

	curr=( $(sed -n "s/^Listen.*\([^\:\. ][0-9].*\)/\1/p" "$httpdconf") )
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

###############################################################################
## Functions for retrieving/setting AJP host and port in httpd.conf
###############################################################################

GET_AJP_HOST() {
	# 1: path to httpd.conf
	# return host, or 0 if httpd.conf not found
	local curr httpdconf

	httpdconf=$1
	if [ ! -f "$httpdconf" ]; then
		return ""
	fi

	curr=$(sed -n "s/^ProxyPass \/tc\/\? ajp\:\/\/\(.*\)\:\([0-9].*\)\(\/.*\)$/\1/p" "$httpdconf")
	if [ -z "$curr" ]; then
		curr="127.0.0.1"
	fi
	echo -n "$curr"
}

GET_AJP_PORT() {
	# 1: path to httpd.conf
	# return port, or 0 if httpd.conf not found
	local curr httpdconf

	httpdconf=$1
	if [ ! -f "$httpdconf" ]; then
		return 0
	fi

	curr=$(sed -n "s/^ProxyPass \/tc\/\? ajp\:\/\/\(.*\)\:\([0-9].*\)\(\/.*\)$/\2/p" "$httpdconf")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

###############################################################################
## Functions for retrieving/setting AJP host and port in server.xml
###############################################################################

GET_TC_AJP_HOST() {
	# 1: path to server.xml
	# return host, or 0 if server.xml not found
	local curr serverxml

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<Connector.*protocol=\"AJP\/1.3\".*address=\"\([^\"]*\)\".*$/\1/p" "$serverxml")
	if [ -z "$curr" ]; then
		curr="127.0.0.1"
	fi
	echo -n "$curr"
}

GET_TC_AJP_PORT() {
	# 1: path to server.xml
	# return port, or 0 if server.xml not found
	local curr serverxml

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<Connector.*port=\"\([0-9]*\)\".*protocol=\"AJP\/1.3\".*$/\1/p" "$serverxml")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_TC_AJP() {
	# 1: path to server.xml
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port serverxml regex_host regex_port

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^\([[:blank:]]\+\)<Connector\(.*protocol=\"AJP\/1.3\".*\)address=\"\([^\"]*\)\"\(.*\)$/\1<Connector\2address=\"$host\"\4/g"
	regex_port="s/^\([[:blank:]]\+\)<Connector\(.*\)port=\"\([0-9]*\)\"\(.*protocol=\"AJP\/1.3\".*\)$/\1<Connector\2port=\"$port\"\4/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$serverxml"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$serverxml"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$serverxml"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting HTTP host and port in server.xml
###############################################################################

GET_TC_HTTP_HOST() {
	# 1: path to server.xml
	# return host, or 0 if server.xml not found
	local curr serverxml

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<Connector.*protocol=\"HTTP\/1.1\".*address=\"\([^\"]*\)\".*$/\1/p" "$serverxml")
	if [ -z "$curr" ]; then
		curr="127.0.0.1"
	fi
	echo -n "$curr"
}

GET_TC_HTTP_PORT() {
	# 1: path to server.xml
	# return port, or 0 if server.xml not found
	local curr serverxml

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 0
	fi

	curr=$(sed -n "s/^[[:blank:]]\+<Connector.*port=\"\([0-9]*\)\".*protocol=\"HTTP\/1.1\".*$/\1/p" "$serverxml")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_TC_HTTP() {
	# 1: path to server.xml
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port serverxml regex_host regex_port

	serverxml=$1
	if [ ! -f "$serverxml" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^\([[:blank:]]\+\)<Connector\(.*protocol=\"HTTP\/1.1\".*\)address=\"\([^\"]*\)\"\(.*\)$/\1<Connector\2address=\"$host\"\4/g"
	regex_port="s/^\([[:blank:]]\+\)<Connector\(.*\)port=\"\([0-9]*\)\"\(.*protocol=\"HTTP\/1.1\".*\)$/\1<Connector\2port=\"$port\"\4/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$serverxml"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$serverxml"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$serverxml"
	fi
	return $?
}

###############################################################################
## Functions for retrieving/setting urls in etl-mngr.properties
###############################################################################

GET_RPC_ETL_HOST() {
	# 1: path to etl-mngr.properties
	# return host, or 0 if etl-mngr.properties not found
	local curr etlmngrprop

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return ""
	fi

	curr=$(sed -n "s/^etl\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\/etlserver\/services\/ETL-Server$/\2/p" "$etlmngrprop")
	if [ -z "$curr" ]; then
		curr="127.0.0.1"
	fi
	echo -n "$curr"
}

GET_RPC_ETL_PORT() {
	# 1: path to etl-mngr.properties
	# return port, or 0 if etl-mngr.properties not found
	local curr etlmngrprop

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return 0
	fi

	curr=$(sed -n "s/^etl\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/\3/p" "$etlmngrprop")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_RPC_ETL() {
	# 1: path to etl-mngr.properties
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port etlmngrprop regex_host regex_port

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^etl\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/etl\.server\.url=http\1:\/\/$host:\3\4/g"
	regex_port="s/^etl\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/etl\.server\.url=http\1:\/\/\2:$port\4/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$etlmngrprop"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$etlmngrprop"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$etlmngrprop"
	fi
	return $?
}

GET_RPC_SCHED_HOST() {
	# 1: path to etl-mngr.properties
	# return host, or 0 if etl-mngr.properties not found
	local curr etlmngrprop

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return ""
	fi

	curr=$(sed -n "s/^scheduler\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/\2/p" "$etlmngrprop")
	if [ -z "$curr" ]; then
		curr="127.0.0.1"
	fi
	echo -n "$curr"
}

GET_RPC_SCHED_PORT() {
	# 1: path to etl-mngr.properties
	# return port, or 0 if etl-mngr.properties not found
	local curr etlmngrprop

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return 0
	fi

	curr=$(sed -n "s/^scheduler\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/\3/p" "$etlmngrprop")
	if [ -z "$curr" ]; then
		return 0
	fi
	echo -n "$curr"
}

SET_RPC_SCHED() {
	# 1: path to etl-mngr.properties
	# 2: host to set, do not replace if empty
	# 3: port to set, do not replace if empty
	local host port etlmngrprop regex_host regex_port

	etlmngrprop=$1
	if [ ! -f "$etlmngrprop" ]; then
		return 1
	fi
	host=$2
	port=$3

	regex_host="s/^scheduler\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/scheduler\.server\.url=http\1:\/\/$host:\3\4/g"
	regex_port="s/^scheduler\.server\.url=http\(\|s\):\/\/\(.*\):\([0-9]\{1,6\}\)\(.*\)$/scheduler\.server\.url=http\1:\/\/\2:$port\4/g"

	if [ ! -z "$host" ] && [ ! -z "$port" ]; then
		sed -i.bak "$regex_host; $regex_port" "$etlmngrprop"
	elif [ ! -z "$host" ]; then
		sed -i.bak "$regex_host" "$etlmngrprop"
	elif [ ! -z "$port" ]; then
		sed -i.bak "$regex_port" "$etlmngrprop"
	fi
	return $?
}

SET_SCHED_WEBHOST() {
	# 1: path to tomcat/webapps/schedulerserver/config/components.properties
	# 2: host to set
	# 3: port to set
	local host port entry cmptsprop

	cmptsprop=$1
	#if [ ! -f "$cmptsprop" ]; then
	#	return 1
	#fi
	host=$2
	port=$3

	if [ -z "$host" ]; then
		host="127.0.0.1"
	fi

	entry="paloWebHost = $host"

	if [ ! -z "$port" ]; then
		entry="$entry:$port"
	fi
	echo "$entry" > "$cmptsprop"
	return $?
}

###############################################################################
## Installation routine: super user permissions, EULA agreement, install path
###############################################################################

# Check if we have superuser rights
if [[ $UID -ne 0 ]]; then
  echo "$0 must be run as root!"
  exit 1
fi

# Check if the chroot command can be successfully executed
if ! CHROOT_ENABLED; then
  echo "It seems that the use of the chroot command is blocked even for root."
  echo "The chroot command must be allowed in order for Jedox to work!"
  exit 1
fi

# Check if the install package exists
if [ ! -f $INSTALL_PACKAGE ]; then
  echo "Please start the script in the directory containing the $INSTALL_PACKAGE archive"
  exit 1
fi

# If the ".lic_agr_$VERSION" file exists don't ask for agreement
if [ ! -f "$CURRENT_PATH/.lic_agr_$VERSION" ]; then
  more "$CURRENT_PATH/LICENSE.txt"
  read -p "Do you accept the previously read EULA ? [y|N]: " LIC_AGREE
  case "$LIC_AGREE" in
    [Yy])
      echo "accepted" > "$CURRENT_PATH/.lic_agr_$VERSION"
    ;;
    "" | *)
      echo "The EULA must be accepted to install the Jedox Suite $VERSION"
      echo "The installation/update has been stopped."
      exit 1
    ;;
  esac
fi

echo
echo "This script will install the Jedox Suite $VERSION on your system"
echo
echo "During the installation you will be asked several questions about your system. If you don't know the answer to a question you can abort the installation at any time by pressing CTRL+C. Pressing CTRL+Z will stop the installation temporarily. You can restart the session by entering 'fg' on the command prompt. The installation program offers you some default values which are safe to accept on most systems, just press enter when you want to accept such an offer."


if [ ! $SILENT_INSTALL ]; then
	echo
	echo "Please enter the path to where you want the Jedox Suite $VERSION to be installed"
	read -p "Default [$INSTALL_PATH]: " IN_PATH
	
	if [ ! -z "$IN_PATH" ]; then
  		INSTALL_PATH=$IN_PATH
	fi
fi


###############################################################################
## Now that we have the install path, we set all the dependent path variables
###############################################################################

STORAGE_PATH="$INSTALL_PATH/$DIR_NAME_STORAGE"
DATA_PATH="$INSTALL_PATH/$DIR_NAME_DATA"
ETL_DATA_PACKAGE="$INSTALL_PATH/$ETL_DATA_PACKAGE"
ETL_DATA_PATH="$INSTALL_PATH/$ETL_DATA_PATH"

# Location of the various configuration files
PALO_INI="$DATA_PATH/palo.ini"
SSS_CONFIG_XML="$INSTALL_PATH/core-Linux-i686/etc/config.xml"
SSS_PALO_XML="$INSTALL_PATH/core-Linux-i686/etc/palo_config.xml"
SSS_FONT_XML="$INSTALL_PATH/core-Linux-i686/etc/font_config.xml"
SSS_UIBACKEND_XML="$INSTALL_PATH/core-Linux-i686/etc/ui_backend_config.xml"
SVS_PHP_INI="$INSTALL_PATH/svs-Linux-i686/php.ini"
HTTPD_CONF="$INSTALL_PATH/etc/httpd/conf/httpd.conf"
WEB_CONFIG_PHP="$INSTALL_PATH/htdocs/app/etc/config.php"
TOMCAT_SERVER_XML="$INSTALL_PATH/tomcat/conf/server.xml"
ETL_MNGR_PROPS="$INSTALL_PATH/tomcat/webapps/rpc/WEB-INF/classes/etl-mngr.properties"
SCHED_CMPTS="$INSTALL_PATH/tomcat/webapps/schedulerserver/config/components.properties"

###############################################################################
## Check if we are doing a fresh install or not.
## On upgrade: read host and port configuration from a previous installation.
###############################################################################

# Are we performing a fresh installation or an upgrade?
if [ ! -d "$INSTALL_PATH" ]
then
	if [ ! $SILENT_INSTALL ]; then

	  read -p "The directory $INSTALL_PATH does not exist. Shall I create it ? [Y|n]: " CREATE
	  case "$CREATE" in
	    "" | [Yy])
	      mkdir -p "$INSTALL_PATH"
	    ;;
	    *)
	      echo "You will have to specify another path then!"
	      echo "Please restart the installation..."
	      exit 1
	    ;;
	  esac
	else
		echo "The directory $INSTALL_PATH does not exist. I will create it."
		mkdir -p "$INSTALL_PATH"

	fi
else
  #############################################################################
	## If the install path is not empty, check if the configured ports are free.
	## If not, warn and tell to shutdown all components.
	## Unmount the suites special dirs, before upgrading the installation.
	#############################################################################
	if ! DIR_IS_EMPTY "$INSTALL_PATH"; then
		IS_UPGRADE=true
		
		echo "unset der Jedox Vars"
		# Load the Jedox Suite variables
		unset JEDOX_VERSION
		unset JEDOX_USER
		unset JEDOX_GROUP
		unset JEDOX_ADDON
		unset JEDOX_CORE

		if [ -e "$INSTALL_PATH/etc/jedoxenv.sh" ]; then
			. "$INSTALL_PATH/etc/jedoxenv.sh"
		fi

		echo -ne "=> Upgrading $INSTALL_PATH"
		if [ -z "$JEDOX_VERSION" ]; then
			JEDOX_VERSION="3"
			echo -ne " containing Jedox 3.3 or below"
		else
			echo -ne " containing Jedox $JEDOX_VERSION"
		fi
		echo

		# Read host and port config for SSS from the following file
		SSS_UIBACKEND_XML_R="$SSS_UIBACKEND_XML"

		# we need to check if any 64bit components were enabled before the upgrade
		if [ "$JEDOX_CORE" == "core64" ]; then
			SSS_UIBACKEND_XML_R="$INSTALL_PATH/core-Linux-x86_64/etc/ui_backend_config.xml"
		fi

		# get the hosts and ports for most of the configuration files
		# overwrite the HOST_<component> and PORT_<component> variables

		# OLAP host configuration
		DEF_HOST_OLAP=$(GET_OLAP_HOST "$PALO_INI")
		if [ ! -z "$DEF_HOST_OLAP" ]; then
			HOST_OLAP="$DEF_HOST_OLAP"
		fi
		if [ "$HOST_OLAP" == "\"\"" ]; then
			TEST_HOST_OLAP="127.0.0.1"
		else
			TEST_HOST_OLAP="$HOST_OLAP"
		fi

		# OLAP port configuration
		DEF_PORT_OLAP=$(GET_OLAP_PORT "$PALO_INI")
		if [ "${DEF_PORT_OLAP:-0}" -gt "0" ]; then
			PORT_OLAP="$DEF_PORT_OLAP"
		fi

		# HTTP host configuration
		[[ -f "$INSTALL_PATH/usr/local/apache2/conf/httpd.conf" ]] && HTTPD_CONF="$INSTALL_PATH/usr/local/apache2/conf/httpd.conf" # upgrade Jedox 3.X or below
		[[ -f "$INSTALL_PATH/etc/httpd/conf/httpd.conf" ]] && HTTPD_CONF="$INSTALL_PATH/etc/httpd/conf/httpd.conf" # upgrade Jedox 4.X and above
		TEST_HOST_HTTP=$(GET_HTTPD_HOST "$HTTPD_CONF")
		if [ ! -z "$TEST_HOST_HTTP" ]; then
			HOST_HTTP="$TEST_HOST_HTTP"
		else
			TEST_HOST_HTTP="127.0.0.1"
		fi

		# HTTP port configuration
		DEF_PORT_HTTP=$(GET_HTTPD_PORT "$HTTPD_CONF")
		if [ "${DEF_PORT_HTTP:-0}" -gt "0" ]; then
			PORT_HTTP="$DEF_PORT_HTTP"
		fi

		# It's important to now set HTTPD_CONF to the proper value,
		# because we will not use the one in the old location anymore
		HTTPD_CONF="$INSTALL_PATH/etc/httpd/conf/httpd.conf"

		# SSS host configuration
		DEF_HOST_SSS=$(GET_SSS_HOST "$SSS_UIBACKEND_XML_R")
		if [ ! -z "$DEF_HOST_SSS" ]; then
			HOST_SSS="$DEF_HOST_SSS"
		fi

		# SSS port configuration
		DEF_PORT_SSS=$(GET_SSS_PORT "$SSS_UIBACKEND_XML_R")
		if [ "${DEF_PORT_SSS:-0}" -gt "0" ]; then
			PORT_SSS="$DEF_PORT_SSS"
		fi

		# TC AJP host configuration
		DEF_HOST_TC_AJP=$(GET_TC_AJP_HOST "$TOMCAT_SERVER_XML")
		if [ ! -z "$DEF_HOST_TC_AJP" ]; then
			HOST_TC_AJP="$DEF_HOST_TC_AJP"
		fi

		# TC AJP port configuration
		DEF_PORT_TC_AJP=$(GET_TC_AJP_PORT "$TOMCAT_SERVER_XML")
		if [ "${DEF_PORT_TC_AJP:-0}" -gt "0" ]; then
			PORT_TC_AJP="$DEF_PORT_TC_AJP"
		fi

		# TC HTTP host configuration
		DEF_HOST_TC_HTTP=$(GET_TC_HTTP_HOST "$TOMCAT_SERVER_XML")
		if [ ! -z "$DEF_HOST_TC_HTTP" ]; then
			HOST_TC_HTTP="$DEF_HOST_TC_HTTP"
		fi

		# TC HTTP port configuration
		DEF_PORT_TC_HTTP=$(GET_TC_HTTP_PORT "$TOMCAT_SERVER_XML")
		if [ "${DEF_PORT_TC_HTTP:-0}" -gt "0" ]; then
			PORT_TC_HTTP="$DEF_PORT_TC_HTTP"
		fi

		# check for running components via host and port
		# we can not rely on the jedox-suite.sh status command
		# because there was no such script in Jedox < v4
		OLAP_RUNNING=true
		HTTPD_RUNNING=true
		SSS_RUNNING=true
		TC_RUNNING=true
		
		# check which components are running
		if TCP_FREE "$TEST_HOST_OLAP" "$PORT_OLAP"; then
			OLAP_RUNNING=
		fi
		if TCP_FREE "$TEST_HOST_HTTP" "$PORT_HTTP"; then
			HTTPD_RUNNING=
		fi
		if TCP_FREE "$HOST_SSS" "$PORT_SSS"; then
			SSS_RUNNING=
		fi
		if TCP_FREE "$HOST_TC_AJP" "$PORT_TC_AJP"; then
			TC_RUNNING=
		fi
		
		if [ ! -z "$OLAP_RUNNING$HTTPD_RUNNING$SSS_RUNNING$TC_RUNNING" ]; then
		  echo
		  echo "WARNING:"
		  echo "The following components of your old installation are still running:"
		  if [ ! -z "$OLAP_RUNNING" ]; then
		    echo "  OLAP server on port $PORT_OLAP"
		  fi
		  if [ ! -z "$HTTPD_RUNNING" ]; then
		    echo "  Apache server on port $PORT_HTTP"
		  fi
		  if [ ! -z "$SSS_RUNNING" ]; then
		    echo "  Spreadsheet server on port $PORT_SSS"
		  fi
			if [ ! -z "$TC_RUNNING" ]; then
		    echo "  Tomcat server on port $PORT_TC_AJP"
		  fi
		  echo
			# we should not be able to install, if old components are still running (ticket 19777)
			echo "All Jedox components of the old installation must be stopped before an upgrade."
		  echo "Please restart the installation..."
			exit 1
		fi
		
		# attempt to unmount our special dirs in the existing installation
		# this refers to ticket 16944
		SPECIAL_DIRS=( "dev" "proc" "sys" )
		for special_dir in "${SPECIAL_DIRS[@]}"; do
		  if [ "$(mount |grep "$INSTALL_PATH/$special_dir")" ]; then
		    umount "$INSTALL_PATH/$special_dir"
		  fi
		done
	fi
fi

###############################################################################
## Specify the user and group which will be used for Jedox
###############################################################################

if [ ! $SILENT_INSTALL ]; then
	echo
	echo "Please enter which user should run and own the Jedox Suite:"
	read -p "Default [$JEDOX_USER]: " IN_USER

	if [ ! -z "$IN_USER" ]; then
  		JEDOX_USER=$IN_USER
	fi

	echo
	echo "Please enter which group should run and own the Jedox Suite:"
	read -p "Default [$JEDOX_GROUP]: " IN_GROUP

	if [ ! -z "$IN_GROUP" ]; then
  		JEDOX_GROUP=$IN_GROUP
	fi
else
	echo "Default user $JEDOX_USER will be created."
	echo "Default group $JEDOX_GROUP will be created."
fi

## Checking for a valid Jedox Suite Group
if ! getent group "$JEDOX_GROUP" >/dev/null 2>&1; then
	if [ ! $SILENT_INSTALL ]; then

	  echo
  		read -p "The group \"$JEDOX_GROUP\" does not exist. Do you want me to create the group? [Y|n]: " CREATE
  		case "$CREATE" in
    	"" | [Yy])
      	if ! (groupadd "$JEDOX_GROUP" --force --system  >/dev/null 2>&1;) then
        	echo "There was a problem creating the group."
        	exit 1
      	fi
    	;;
    	*)
      	echo "You will have to specify another username then!"
      	echo "Please restart the installation..."
      	exit 1
    	;;
  	esac
	else
		if ! (groupadd "$JEDOX_GROUP" --force --system  >/dev/null 2>&1;) then
        	echo "There was a problem creating the group."
        	exit 1
      	fi
	fi
fi

## Checking for a valid Jedox Suite user.
if ! getent passwd "$JEDOX_USER" >/dev/null 2>&1; then
	if [ ! $SILENT_INSTALL ]; then
		echo
	  read -p "The user \"$JEDOX_USER\" does not exist. Do you want me to create the user? [Y|n]: " CREATE
	  case "$CREATE" in
    	"" | [Yy])
      	if ! (useradd "$JEDOX_USER" -g "$(GROUPID_BY_NAME "$JEDOX_GROUP")" -M -r -s /sbin/nologin -c "Jedox Suite user - created during the installation." >/dev/null 2>&1;) then
        	echo "There was a problem creating the user."
        	exit 1
      	fi
    	;;
    	*)
      	echo "You will have to specify another username then!"
      	echo "Please restart the installation..."
      	exit 1
    	;;
  	esac
	else
		if ! (useradd "$JEDOX_USER" -g "$(GROUPID_BY_NAME "$JEDOX_GROUP")" -M -r -s /sbin/nologin -c "Jedox Suite user - created during the installation." >/dev/null 2>&1;) then
        	echo "There was a problem creating the user."
        	exit 1
      	fi
	fi
fi
echo

###############################################################################
## Installation routine: backup old data before starting file deployment
###############################################################################

if $IS_UPGRADE ; then
  echo
  echo -n "Backing up configuration and database files..."
  BACKUP_DIR=upgrade_$(date +%d%m%Y%H%M%S)
  BACKUP_PATH=$INSTALL_PATH/$BACKUP_DIR
  # We are doing an upgrade and we want our new installation to be clean.
  # So we wipe all the old and obsolete files, but the important ones.
  # In order to do that, we will first save the important files and then
  # delete almost everything else. After that we copy the saved files back
  # to their original place.
  
  # Create directories and copy files
  if [ -d "$INSTALL_PATH"/etc ]; then
    mkdir -p "$BACKUP_PATH"/etc/
    cp -aR "$INSTALL_PATH"/etc/* "$BACKUP_PATH"/etc/
  fi
  
  if [ -d "$INSTALL_PATH"/svs-Linux-i686 ]; then
    mkdir -p "$BACKUP_PATH"/svs-Linux-i686
    cp -aR "$INSTALL_PATH"/svs-Linux-i686/* "$BACKUP_PATH"/svs-Linux-i686/
  fi
  
  if [ -d "$INSTALL_PATH"/core-Linux-i686/etc ]; then
    mkdir -p "$BACKUP_PATH"/core-Linux-i686/etc/
    cp -aR "$INSTALL_PATH"/core-Linux-i686/etc/* "$BACKUP_PATH"/core-Linux-i686/etc/
  fi
  
  if [ -d "$INSTALL_PATH"/core-Linux-x86_64/etc ]; then
    mkdir -p "$BACKUP_PATH"/core-Linux-x86_64/etc/
    cp -aR "$INSTALL_PATH"/core-Linux-x86_64/etc/* "$BACKUP_PATH"/core-Linux-x86_64/etc/
  fi
  
  if [ -d "$INSTALL_PATH"/htdocs/app/etc ]; then
    mkdir -p "$BACKUP_PATH"/htdocs/app/etc/
    cp -aR "$INSTALL_PATH"/htdocs/app/etc/* "$BACKUP_PATH"/htdocs/app/etc/
  fi
  
  if [ -d "$INSTALL_PATH"/htdocs/app/docroot/pr  ]; then
    mkdir -p "$BACKUP_PATH"/htdocs/app/docroot/pr/
    cp -aR "$INSTALL_PATH"/htdocs/app/docroot/pr/* "$BACKUP_PATH"/htdocs/app/docroot/pr/
    rm -rf "$BACKUP_PATH"/htdocs/app/docroot/pr/jedox
  fi
  
  if [ -d "$INSTALL_PATH"/usr/local/apache2/conf ]; then
    mkdir -p "$BACKUP_PATH"/usr/local/apache2/conf/
    cp -aR "$INSTALL_PATH"/usr/local/apache2/conf/* "$BACKUP_PATH"/usr/local/apache2/conf/
  fi

	if [ -f "$INSTALL_PATH/tomcat/bin/setenv.sh" ]; then
    mkdir -p "$BACKUP_PATH/tomcat/bin"
    cp -aR "$INSTALL_PATH/tomcat/bin/setenv.sh" "$BACKUP_PATH/tomcat/bin/"
  fi
  
  if [ -d "$ETL_DATA_PATH" ]; then
    mkdir -p "$BACKUP_PATH"/tomcat/webapps/etlserver/data/
    cp -aR "$ETL_DATA_PATH"/* "$BACKUP_PATH"/tomcat/webapps/etlserver/data/
  fi
  
  if [ -d "$INSTALL_PATH"/rdb ]; then
    mkdir -p "$BACKUP_PATH"/rdb/
    cp -aR "$INSTALL_PATH"/rdb/* "$BACKUP_PATH"/rdb/
  fi
  
  if [ -d "$STORAGE_PATH" ]; then
    mkdir -p "$BACKUP_PATH/$DIR_NAME_STORAGE/"
    cp -aR "$STORAGE_PATH"/* "$BACKUP_PATH/$DIR_NAME_STORAGE/"
  fi
  
  if [ -d "$DATA_PATH" ]; then
    mkdir -p "$BACKUP_PATH/$DIR_NAME_DATA/"
    cp -aR "$DATA_PATH"/* "$BACKUP_PATH/$DIR_NAME_DATA/"
  fi
  
  if [ -f "$INSTALL_PATH/tomcat/conf" ]; then
    mkdir -p "$BACKUP_PATH"/tomcat/conf
		cp -aR "$INSTALL_PATH"/tomcat/conf/* "$BACKUP_PATH"/tomcat/conf/
    # cp "$INSTALL_PATH"/tomcat/conf/server.xml "$BACKUP_PATH"/tomcat/conf/server.xml.bak
  fi
  
  # back up old bash scripts and other files
  for FILE in "$INSTALL_PATH"/* ; do
    if [ -f "$FILE" ]; then
      mv "$FILE" "$BACKUP_PATH/"
    fi
  done
  echo "done."
  
  echo -n "Cleaning the installation folder..."
  # Now wipe all files and folders which belong to the chroot jail
  tar -tzf $INSTALL_PACKAGE | sed -e 's@/.*@@' | uniq | while read line; do rm -Rf "$INSTALL_PATH/$line"; done
  echo "done."
  
  echo -n "Copying relevant files back into your installation directory..."
  if [ -d "$BACKUP_PATH"/core-Linux-i686 ]; then
    cp -aR "$BACKUP_PATH"/core-Linux-i686 "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/core-Linux-x86_64 ]; then
    cp -aR "$BACKUP_PATH"/core-Linux-x86_64 "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/svs-Linux-i686 ]; then
    cp -aR "$BACKUP_PATH"/svs-Linux-i686 "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/svs-Linux-x86_64 ]; then
    cp -aR "$BACKUP_PATH"/svs-Linux-x86_64 "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/htdocs ]; then
    cp -aR "$BACKUP_PATH"/htdocs "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/tomcat ]; then
    cp -aR "$BACKUP_PATH"/tomcat "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH"/rdb ]; then
    cp -aR "$BACKUP_PATH"/rdb "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH/$DIR_NAME_STORAGE" ]; then
    cp -aR "$BACKUP_PATH/$DIR_NAME_STORAGE" "$INSTALL_PATH"/
  fi
  
  if [ -d "$BACKUP_PATH/$DIR_NAME_DATA" ]; then
    cp -aR "$BACKUP_PATH/$DIR_NAME_DATA" "$INSTALL_PATH"/
  fi
  
  echo "done."
  
  echo -n "Removing backups from a previous upgrade..."
  for OLDBACKUP in "$INSTALL_PATH"/upgrade_* ; do
    if ([ -d "$OLDBACKUP" ] && [ "$OLDBACKUP" != "$BACKUP_PATH" ]); then
      rm -Rf "$OLDBACKUP"
    fi
  done
  echo "done."
  echo
fi

###############################################################################
## Installation routine: extract the Jedox chroot jail with bin and libs
###############################################################################

echo -n -e "The suite will now be installed. This might take a while ... "
tar zxmf "$INSTALL_PACKAGE" -C "$INSTALL_PATH" && IS_OK=true
if [ -z $IS_OK ]
then
  echo -e "failed!\n"
  echo "There were errors while extracting the tar archive .. please check the archive using the 'tar ztf $INSTALL_PACKAGE' command!"
  exit 1
fi
echo -e "Ok.\n"

###############################################################################
## Installation routine: extract the storage files
###############################################################################
if [ -d "$STORAGE_PATH" ]; then
  read -p "The directory $STORAGE_PATH exists. Shall I overwrite it? [y|N]: " OVER_STORAGE
  case "$OVER_STORAGE" in
    [Yy])
      tar zxmf "$STORAGE_PATH.tar.gz" -C "$INSTALL_PATH"
    ;;
    "" | *)
      echo "I will use existing storage data!"
    ;;
  esac
else
  tar zxmf "$STORAGE_PATH.tar.gz" -C "$INSTALL_PATH"
fi

###############################################################################
## Installation routine: extract the OLAP data files
###############################################################################
if [ -d "$DATA_PATH" ]; then
  read -p "The directory $DATA_PATH exists. Shall I overwrite it? [y|N]: " OVER_DATA
  case "$OVER_DATA" in
    [Yy])
			DATA_REPLACED=true
      tar zxmf "$DATA_PATH.tar.gz" -C "$INSTALL_PATH"
    ;;
    "" | *)
      echo "I will use existing data!"
      sed -i.bak "/user-login/d" "$PALO_INI"
      sed -i "/keep-trying/d" "$PALO_INI"
      sed -i "/clear-cache/d" "$PALO_INI"
      sed -i "/rule-cache-size/d" "$PALO_INI"
      sed -i "/initial-thread-pool/d" "$PALO_INI"
      sed -i "/max-subjobs/d" "$PALO_INI"
      sed -i "/cache-size/d" "$PALO_INI"
      sed -i "/processors-cores/d" "$PALO_INI"
      sed -i "/clear-cache-cells/d" "$PALO_INI"
      # OLAP 4.1 has introduced "extension <directory>", it must be defined in palo.ini
      sed -i "/extension/d" "$PALO_INI"
      echo "extension /usr/lib" >> "$PALO_INI"
    ;;
  esac
else
  tar zxmf "$DATA_PATH.tar.gz" -C "$INSTALL_PATH"
fi

###############################################################################
## Installation routine: extract the ETL data files
###############################################################################


if [ -d "$ETL_DATA_PATH" ]; then
	if [ ! $SILENT_INSTALL ]; then
  		read -p "The directory $ETL_DATA_PATH exists. Shall I overwrite it? [y|N]: " OVER_ETL
  		case "$OVER_ETL" in
    		[Yy])
      		tar zxmf "$ETL_DATA_PACKAGE.tar.gz" -C "$ETL_DATA_PATH"
    	;;
    	"" | *)
      	echo "I will use existing ETL data!"
    	;;
  		esac
	else
		echo "I will use existing ETL data!"
	fi
else
  mkdir -p "$ETL_DATA_PATH"
  tar zxmf "$ETL_DATA_PACKAGE.tar.gz" -C "$ETL_DATA_PATH"
fi

###############################################################################
## Copy various configuration files to the jail
###############################################################################
cd "$INSTALL_PATH/etc"

if [ -f "_localtime" ]; then
  rm  "_localtime"
fi

if [ -f "/etc/localtime" ]; then
  if [ -f "localtime" ]; then
    mv "localtime" "_localtime"
  fi
  cp "/etc/localtime" "localtime"
fi

if [ -f "/etc/timezone" ]; then
  cp "/etc/timezone" "timezone"
fi

if [ -f "/etc/resolv.conf" ]; then
  cp "/etc/resolv.conf" "resolv.conf"
  elif [ ! -f "resolv.conf" ]; then
  mv "resolv.tpl" "resolv.conf"
fi

if [ -f "/etc/hosts" ]; then
  cp "/etc/hosts" "hosts"
fi

###############################################################################
## Put ssl certificates and keys in place, if they do not exist yet
###############################################################################
cd "$INSTALL_PATH/etc/httpd/ssl.crt"

if [ ! -f server.crt ]; then
  cp server.crt.template server.crt
fi

cd "$INSTALL_PATH/etc/httpd/ssl.csr"
if [ ! -f server.csr ]; then
  cp server.csr.template server.csr
fi

cd "$INSTALL_PATH/etc/httpd/ssl.key"
if [ ! -f server.key ]; then
  cp server.key.template server.key
fi

###############################################################################
## Copy some more files from the backup if they exist, upgrade them
###############################################################################
cd "$INSTALL_PATH/etc"

# /etc/odbc.ini
if [ -f "$BACKUP_PATH/etc/odbc.ini" ]; then
  rm -f "odbc.ini"
  cp -f "$BACKUP_PATH/etc/odbc.ini" "odbc.ini"
else
  if [ ! -f "odbc.ini" ]; then
    cp "odbc.ini.tpl" "odbc.ini"
  fi
fi

# /etc/odbcinst.ini
if [ -f "$BACKUP_PATH/etc/odbcinst.ini" ]; then
  rm -f "odbcinst.ini"
  cp -f "$BACKUP_PATH/etc/odbcinst.ini" "odbcinst.ini"
else
  if [ ! -f "odbcinst.ini" ]; then
    cp "odbcinst.ini.tpl" "odbcinst.ini"
  fi
fi

# /tomcat/bin/setenv.sh
cd "$INSTALL_PATH/tomcat/bin"
if [ -f "$BACKUP_PATH/tomcat/bin/setenv.sh" ]; then
  rm -f "setenv.sh"
  cp -f "$BACKUP_PATH/tomcat/bin/setenv.sh" "setenv.sh"
fi

# /etc/php.ini
cd "$INSTALL_PATH/etc"
cp "php.ini.tpl" "php.ini"

# Convert Web UI config.php format from v3.3 -> 5.1
# If the file does not exist, use the template
if [ ! -f "$WEB_CONFIG_PHP" ]; then
  sed -i 's/'"$(printf '\015')"'$//g' "$WEB_CONFIG_PHP.tpl"
  cp "$WEB_CONFIG_PHP.tpl" "$WEB_CONFIG_PHP"
else
  # old config already present - backup
  sed -i 's/'"$(printf '\015')"'$//g' "$WEB_CONFIG_PHP"
  cp "$WEB_CONFIG_PHP" "$WEB_CONFIG_PHP.bak"
fi

###############################################################################
## Replicate user and group into the jail, if they do not exist yet
###############################################################################

HOST_JEDOX_USERID=$(USERID_BY_NAME "$JEDOX_USER")
HOST_JEDOX_GROUPID=$(GROUPID_BY_NAME "$JEDOX_GROUP")

if chroot "$INSTALL_PATH" getent group "$JEDOX_GROUP" >/dev/null 2>&1; then
  chroot "$INSTALL_PATH" groupmod -o -g "$HOST_JEDOX_GROUPID" "$JEDOX_GROUP" >/dev/null 2>&1;
else
  chroot "$INSTALL_PATH" groupadd -o -g "$HOST_JEDOX_GROUPID" "$JEDOX_GROUP" --force --system  >/dev/null 2>&1;
fi

if chroot "$INSTALL_PATH" getent passwd "$JEDOX_USER" >/dev/null 2>&1; then
  chroot "$INSTALL_PATH" usermod -o -u "$HOST_JEDOX_USERID" -g "$HOST_JEDOX_GROUPID" "$JEDOX_USER" -s /sbin/nologin >/dev/null 2>&1;
else
  chroot "$INSTALL_PATH" useradd -o -u "$HOST_JEDOX_USERID" -g "$HOST_JEDOX_GROUPID" "$JEDOX_USER" -M -r -s /sbin/nologin >/dev/null 2>&1;
fi

#if [ -f "/etc/passwd" ]; then
#	sed -i "/$JEDOX_USER/d;" "$INSTALL_PATH/etc/passwd"
#	grep "$JEDOX_USER" "/etc/passwd" >> "$INSTALL_PATH/etc/passwd"
#fi

#if [ -f "/etc/group" ]; then
#	sed -i "/$JEDOX_GROUP/d;" "$INSTALL_PATH/etc/group"
#	grep "$JEDOX_GROUP" "/etc/group" >> "$INSTALL_PATH/etc/group"
#fi

###############################################################################
## All files have been copied. Now ask for the configuration:
###############################################################################
cd "$INSTALL_PATH"

# Server-Hostname and Email address

if COMMAND_EXISTS ip; then
	# use an array so we store all primary global addresses in the var but get only the first with "$SERVER_IP"
	SERVER_IP=( $(LANG=en_GB@euro ip addr show scope global primary | sed -n '/inet /p' | sed -e 's: *inet \([^ /]*\).*:\1:') )
	elif COMMAND_EXISTS ifconfig; then
	SERVER_IP=$(LANG=en_GB@euro ifconfig eth0 | sed -n '/inet addr/p' | sed -e 's/.*addr:\([^ ]*\).*/\1/')
fi

if [ -z "$SERVER_IP" ]; then
	SERVER_IP="127.0.0.1"
fi

if COMMAND_EXISTS hostname; then
  SERVER_DNS=$(hostname)
fi
if [ -z "$SERVER_DNS" ]; then
  SERVER_DNS=$SERVER_IP
fi

if [ ! $SILENT_INSTALL ]; then

	echo

	read -p "What is this servers name ? (If no DNS-Server is running take the IP) [$SERVER_DNS]: " SERVER_NAME
	if [ ! -z "$SERVER_NAME" ]; then
	  SERVER_DNS=$SERVER_NAME
	fi

	read -p "What is this servers IP-Address ? [$SERVER_IP]: " USER_SERVER_IP
	if [ ! -z "$USER_SERVER_IP" ]; then
	  SERVER_IP="$USER_SERVER_IP"
	fi

	read -p "Who should get administrative e-mails regarding this server ? [webmaster@$SERVER_DNS]: " EMAILS
	if [ -z "$EMAILS" ]; then
	  SERVER_ADMIN="webmaster@$SERVER_DNS"
	else
	  SERVER_ADMIN="$EMAILS"
	fi
	echo
fi

# 1) OLAP
ALL_OLAP="$HOST_OLAP"
if [ "$HOST_OLAP" == "\"\"" ]; then
	ALL_OLAP="all"
fi

if [ ! $SILENT_INSTALL ]; then

	read -p "Which IP-address should the OLAP server run on (\"all\" for all interfaces) ? [$ALL_OLAP]: " USER_HOST_OLAP
	if [ ! -z "$USER_HOST_OLAP" ]; then
		HOST_OLAP="$USER_HOST_OLAP"
		if [ "$USER_HOST_OLAP" == "all" ]; then
			HOST_OLAP="\"\""
		fi
	fi

	read -p "Which port should the OLAP server run on ? [$PORT_OLAP]: " USER_PORT_OLAP
	if [ ! -z "$USER_PORT_OLAP" ]; then
		PORT_OLAP="$USER_PORT_OLAP"
	fi
fi

# set settings in palo.ini
if SET_OLAP "$PALO_INI" "$HOST_OLAP" "$PORT_OLAP"; then
	if [ -z "$HOST_OLAP" ]; then
		echo "The OLAP server will now listen on port $PORT_OLAP."
	else
		echo "The OLAP server will now run at address $HOST_OLAP on port $PORT_OLAP."
	fi
else
	echo "ERROR: There was a problem writing the new settings to palo.ini."
	echo "ERROR: Please correct the settings in $PALO_INI manually."
fi

# if OLAP binds to all addresses, use 127.0.0.1 for SSS, SVS, Web UI configuration
if [ "$HOST_OLAP" == "\"\"" ]; then
	HOST_OLAP="127.0.0.1"
fi

# set settings in palo_config.xml
if SET_SSS_OLAP "$SSS_PALO_XML" "$HOST_OLAP" "$PORT_OLAP"; then
	echo "Successfully configured OLAP host $HOST_OLAP and port $PORT_OLAP in palo_config.xml."
else
	echo "ERROR: There was a problem writing the new settings to palo_config.xml."
	echo "ERROR: Please correct the settings in $SSS_PALO_XML manually."
fi

# set settings in Supervision-Server php.ini
if SET_SVS "$SVS_PHP_INI" "$HOST_OLAP" "$PORT_OLAP"; then
	echo "Successfully configured OLAP host $HOST_OLAP and port $PORT_OLAP in php.ini."
else
	echo "ERROR: There was a problem writing the new host setting to php.ini."
	echo "ERROR: Please correct the settings in $SVS_PHP_INI manually."
fi

# set host settings in config.php
if PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_PALO_HOST" "'$HOST_OLAP'"; then
	echo "Successfully configured host $HOST_OLAP in config.php."
else
	echo "ERROR: There was a problem writing the new host setting to config.php."
	echo "ERROR: Please correct the settings in $WEB_CONFIG_PHP manually."
fi

# set port settings in config.php
if PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_PALO_PORT" "'$PORT_OLAP'"; then
	echo "Successfully configured port $PORT_OLAP in config.php."
else
	echo "ERROR: There was a problem writing the new port setting to config.php."
	echo "ERROR: Please correct the settings in $WEB_CONFIG_PHP manually."
fi
echo

# 2) Apache
# In order to make RPC work, we must listen at least at 127.0.0.1
LISTEN_LOCALHOST=
ALL_HTTPD="$HOST_HTTP"
if [ -z "$HOST_HTTP" ]; then
	ALL_HTTPD="all"
fi

if [ ! $SILENT_INSTALL ]; then

	read -p "Which IP-address should the HTTP server listen on (\"all\" for all interfaces) ? [$ALL_HTTPD]: " USER_HOST_HTTP
	if [ ! -z "$USER_HOST_HTTP" ]; then
		if [ "$USER_HOST_HTTP" == "all" ]; then
			HOST_HTTP=""
		elif [ "$USER_HOST_HTTP" == "localhost" ]; then
			HOST_HTTP="127.0.0.1"
		elif [ "$USER_HOST_HTTP" == "127.0.0.1" ]; then
			HOST_HTTP="127.0.0.1"
		else
			HOST_HTTP="$USER_HOST_HTTP"
			LISTEN_LOCALHOST="Listen 127.0.0.1"
		fi
	fi

	read -p "Which port should the HTTP server run on ? [$PORT_HTTP]: " USER_PORT_HTTP
	if [ ! -z "$USER_PORT_HTTP" ]; then
		PORT_HTTP="$USER_PORT_HTTP"
	fi

fi

echo
if [ ! -z "$HOST_HTTP" ]; then
	echo "Successfully configured host $HOST_HTTP and port $PORT_HTTP in httpd.conf."
	HOST_HTTP="$HOST_HTTP:"
else
	echo "Successfully configured to listen at port $PORT_HTTP on all interfaces in httpd.conf."
fi

if [ ! -z "$LISTEN_LOCALHOST" ]; then
	LISTEN_LOCALHOST="$LISTEN_LOCALHOST:$PORT_HTTP"
	echo "NOTICE: Added 127.0.0.1 as additional interface for internal communication!"
fi

if [ ! $SILENT_INSTALL ]; then
	echo
	read -p "Would you like to access Jedox Web over TLS ? [y/N] " USE_TLS
	case "$USE_TLS" in
	  [Yy])
		echo "I will configure the Jedox Web to use TLS. To obtain real security however you will have to create/obtain your own site certificate!"
		TLS_ONOFF=1
			while ! TCP_FREE "127.0.0.1" "$PORT_TLS" ; do
				echo
				echo "There seems to run a server on port PORT_TLS."
				read -p "Should I configure the Jedox Web to use this port anyway ? [y/N]: " USE_TLS_PORT
				case "$USE_TLS_PORT" in
					[Yy])
					  echo "The Jedox Web TLS will now run at port $PORT_TLS."
					  break
					;;
					*)
						PORT_TLS=$((PORT_TLS+1))
					  read -p "On what port should TLS run then ? [$PORT_TLS]: " USER_PORT_TLS
				  	if [ ! -z "$USER_PORT_TLS" ]; then
							PORT_TLS="$USER_PORT_TLS"
					  fi
					;;
				esac
			done
			SERVER_TLS="Listen $PORT_TLS"
	  ;;
	  *)
		TLS_ONOFF=0
		echo "Jedox Web will now ignore TLS requests!"
		SERVER_TLS=""
	  ;;
	esac
else
	
	case "$USE_TLS" in
	  [Yy])
		echo "I will configure the Jedox Web to use TLS. To obtain real security however you will have to create/obtain your own site certificate!"
		TLS_ONOFF=1
			while ! TCP_FREE "127.0.0.1" "$PORT_TLS" ; do
				echo
				echo "There seems to run a server on port PORT_TLS."
				USE_TLS_PORT=y
				case "$USE_TLS_PORT" in
					[Yy])
					  echo "The Jedox Web TLS will now run at port $PORT_TLS."
					  break
					;;
				esac
			done
			SERVER_TLS="Listen $PORT_TLS"
	  ;;
	  *)
		TLS_ONOFF=0
		echo "Jedox Web will now ignore TLS requests!"
		SERVER_TLS=""
	  ;;
	esac

fi
# set HTTP port in config.php
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_UB_PORT" "$PORT_HTTP"

# add entry to /etc/host
echo "$SERVER_IP $SERVER_NAME" >> "$INSTALL_PATH/etc/host"
echo

# 3) SSS
if [ ! $SILENT_INSTALL ]; then

	read -p "Which IP-address should the Spreadsheet server run on ? [$HOST_SSS]: " USER_HOST_SSS
	if [ ! -z "$USER_HOST_SSS" ]; then
		HOST_SSS="$USER_HOST_SSS"
	fi

	read -p "Which port should the Spreadsheet server run on ? [$PORT_SSS]: " USER_PORT_SSS
	if [ ! -z "$USER_PORT_SSS" ]; then
		PORT_SSS="$USER_PORT_SSS"
	fi

fi
# set the settings in ui_backend_config.xml
if SET_SSS "$SSS_UIBACKEND_XML" "$HOST_SSS" "$PORT_SSS"; then
	echo "Successfully configured SSS host $HOST_SSS and port $PORT_SSS in ui_backend_config.xml."
else
	echo "ERROR: There was a problem writing the new settings to ui_backend_config.xml."
	echo "ERROR: Please correct the settings in $SSS_UIBACKEND_XML manually."
fi
echo

# 4) Tomcat AJP
if [ ! $SILENT_INSTALL ]; then

	read -p "Which AJP-address should the Tomcat server run on ? [$HOST_TC_AJP]: " USER_HOST_TC_AJP
	if [ ! -z "$USER_HOST_TC_AJP" ]; then
		HOST_TC_AJP="$USER_HOST_TC_AJP"
	fi

	read -p "Which AJP port should the Tomcat server run on ? [$PORT_TC_AJP]: " USER_PORT_TC_AJP
	if [ ! -z "$USER_PORT_TC_AJP" ]; then
		PORT_TC_AJP="$USER_PORT_TC_AJP"
	fi
fi

# set the settings in tomcat server.xml
if SET_TC_AJP "$TOMCAT_SERVER_XML" "$HOST_TC_AJP" "$PORT_TC_AJP"; then
	echo "Successfully configured AJP host $HOST_TC_AJP and port $PORT_TC_AJP in server.xml."
else
	echo "ERROR: There was a problem writing the new settings to server.xml."
	echo "ERROR: Please correct the settings in $TOMCAT_SERVER_XML manually."
fi
echo

# 5) Tomcat HTTP
if [ ! $SILENT_INSTALL ]; then

	read -p "Which HTTP-address should the Tomcat server run on ? [$HOST_TC_HTTP]: " USER_HOST_TC_HTTP
	if [ ! -z "$USER_HOST_TC_HTTP" ]; then
		HOST_TC_HTTP="$USER_HOST_TC_HTTP"
	fi

	read -p "Which HTTP port should the Tomcat server run on ? [$PORT_TC_HTTP]: " USER_PORT_TC_HTTP
	if [ ! -z "$USER_PORT_TC_HTTP" ]; then
		PORT_TC_HTTP="$USER_PORT_TC_HTTP"
	fi
fi

# set the settings in tomcat server.xml
if SET_TC_HTTP "$TOMCAT_SERVER_XML" "$HOST_TC_HTTP" "$PORT_TC_HTTP"; then
	echo "Successfully configured HTTP host $HOST_TC_HTTP and port $PORT_TC_HTTP in server.xml."
else
	echo "ERROR: There was a problem writing the new settings to server.xml."
	echo "ERROR: Please correct the settings in $TOMCAT_SERVER_XML manually."
fi

# set the ETL server settings in etl-mngr.properties
if SET_RPC_ETL "$ETL_MNGR_PROPS" "$HOST_TC_HTTP" "$PORT_TC_HTTP"; then
	echo "Successfully configured ETL-server host $HOST_TC_HTTP and port $PORT_TC_HTTP in etl-mngr.properties."
else
	echo "ERROR: There was a problem writing the new settings to etl-mngr.properties."
	echo "ERROR: Please correct the settings in $ETL_MNGR_PROPS manually."
fi

# set the Scheduler server settings in etl-mngr.properties
if SET_RPC_SCHED "$ETL_MNGR_PROPS" "$HOST_TC_HTTP" "$PORT_TC_HTTP"; then
	echo "Successfully configured Scheduler server host $HOST_TC_HTTP and port $PORT_TC_HTTP in etl-mngr.properties."
else
	echo "ERROR: There was a problem writing the new settings to etl-mngr.properties."
	echo "ERROR: Please correct the settings in $ETL_MNGR_PROPS manually."
fi
echo

# set the Apache host and port in Scheduler servers components.properties
if SET_SCHED_WEBHOST "$SCHED_CMPTS" "$HOST_HTTP" "$PORT_HTTP"; then
	echo "Successfully configured Apache host and port in the Scheduler servers components.properties."
else
	echo "ERROR: There was a problem writing to the Scheduler servers components.properties."
	echo "ERROR: Please correct the entry in $SCHED_CMPTS manually to \"paloWebHost = host(:port)\", using Apaches host and port."
fi
echo

# 6) Finally set the settings in httpd.conf
echo -ne "Writing final configuration to httpd.conf..."
REPLACE_CONF_TAGS="s/SERVER_ADMIN/$SERVER_ADMIN/g; s/SERVER_IP/$SERVER_IP/g; s/HOST_HTTP/$HOST_HTTP/g; s/PORT_HTTP/$PORT_HTTP/g; s/LISTEN_LOCALHOST/$LISTEN_LOCALHOST/g; s/PORT_TLS/$PORT_TLS/g; s/SERVER_TLS/$SERVER_TLS/g; s/SERVER_DNS/$SERVER_DNS/g; s/HOST_SSS/$HOST_SSS/g; s/PORT_SSS/$PORT_SSS/g; s/HOST_TC_AJP/$HOST_TC_AJP/g; s/PORT_TC_AJP/$PORT_TC_AJP/g; s/USER_PLACEHOLDER/$JEDOX_USER/g; s/GROUP_PLACEHOLDER/$JEDOX_GROUP/g;"
sed "$REPLACE_CONF_TAGS" "$HTTPD_CONF.tpl" > "$HTTPD_CONF"
echo "done."

###############################################################################
## Web UI config.php settings and machine ID
###############################################################################
# retrieve some unlikely-to-change but unique data, generate md5 hash and cut it down to 16 characters
# this is done in order to generate a unique machine id
MACHINE_ID=
if COMMAND_EXISTS ip; then
  # try mac addresses first as most hosts use on-board networking devices
  MACHINE_ID="$(LANG=en_GB@euro ip addr show | sed -n '\:link/ether :s: *link/ether \([^ ]*\).*:\1:p')"
  elif COMMAND_EXISTS hdparm; then
  # try HDD serial numbers as fallback
  for x in {a..z}; do
    if test $(ls /dev |grep sd$x |wc -l) != 0; then
      MACHINE_ID="${MACHINE_ID}$(hdparm -i /dev/sd$x | sed -ne '/SerialNo/{s/.*SerialNo=\s*\(.*\)/\1/ ; p}')"
    fi
  done
  #else
  # What should we do for fallback? Generate a random string or use some config values?
fi
MACHINE_ID=$(echo -ne "$MACHINE_ID" | md5sum | cut -c 1-16)

# set cfg version
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_VERSION" "'$VERSION.0'"
# set machine id
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "MACHINE_ID" "'$MACHINE_ID'"
# set fopper path
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_FOPPER_PATH" "'/tc/rpc'"
# set log path to the only good value
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_LOG_PATH" "'/log'"
# set the temporary directory to /tmp
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_TMP_DIR" "'/tmp'"
# disable sso
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_AUTH_SSO" "false"
# disable legacy etl
PHP_CFG_SET_VALUE "$WEB_CONFIG_PHP" "CFG_ETL_LEGACY" "false"
# disable ie8 compat mode if it wasn't configured yet
PHP_CFG_NEW_VALUE "$WEB_CONFIG_PHP" "CFG_IE8_COMPAT_MODE" "false" "// disable ie8 compat mode if it wasn't configured yet"
# disable session pings
PHP_CFG_NEW_VALUE "$WEB_CONFIG_PHP" "CFG_DISABLE_PING" "false" "// disable session pings"
# enable curl conn reuse
PHP_CFG_NEW_VALUE "$WEB_CONFIG_PHP" "CFG_CURL_REUSE" "true" "// enable curl conn reuse"

###############################################################################
## Secret and internal user password settings
###############################################################################
# replace default secret (which is not secret) by newly generated one - leave alone if already changed
NEW_SECRET=$( head -c 500 /dev/urandom | tr -dc a-z0-9A-Z | tr -d ' ' | tr -d '\t' | tr -d '/' | head -c 16 )
PHP_CFG_REPLACE_VALUE "$WEB_CONFIG_PHP" "CFG_SECRET" "'uqtPiM5Nw7MYC2Pl'" "'$NEW_SECRET'"

# retrieve current password
CURRENT_PASS=$( PHP_CFG_GET_VALUE "$WEB_CONFIG_PHP" "CFG_PALO_PASS" )
#echo "CURRENT_PASS is $CURRENT_PASS"

# retrieve current secret
SECRET=$( PHP_CFG_GET_VALUE "$WEB_CONFIG_PHP" "CFG_SECRET" )
#echo "SECRET is $SECRET"

if [ "$CURRENT_PASS" == "_internal_suite" ] || ( $IS_UPGRADE && $DATA_REPLACED ); then
	echo -ne "Generating a new password for the internal user connection..."

  # Generate a 16-character random password
  GENERATED_PASS=$( head -c 500 /dev/urandom | tr -dc a-z0-9A-Z | tr -d ' ' | tr -d '\t' | tr -d '/' | head -c 16 )
	#echo "GENERATED_PASS is $GENERATED_PASS"

  # Write the new password to the System Database
  INTERNAL_USER_ID=$(grep -m1 '_internal_suite' "$DATA_PATH/System/database.csv" | sed "s/\([0-9^;]*\);.*/\1/")
  echo -e "1335433600.562500;\"\";\"\";VERSION;$VER_MAJOR;$VER_MINOR;2;5594;\n1335434884.562500;\"admin\";\"\";SET_STRING;$INTERNAL_USER_ID,0;\"$GENERATED_PASS\";" > "$DATA_PATH/System/database_CUBE_0_0.log"
  
  # Write the new password to the config.php file
  PUT_CFG_PALO_PASS "$WEB_CONFIG_PHP" "$SECRET" "$GENERATED_PASS"
  echo "done."
elif [ "${CURRENT_PASS:0:1}" != "$TAB" ]; then
	echo -ne "Encrypting the internal user password..."
	# if password doesn't start with a tab -> means not encrypted
  # Let's encrypt it for some more safety and then write it back to the config.php file
  PUT_CFG_PALO_PASS "$WEB_CONFIG_PHP" "$SECRET" "$CURRENT_PASS"
	echo "done."
fi

# add secret in palo_config.xml
if [ -f "$SSS_PALO_XML" ]; then
	sed -i "/secret/d;" "$SSS_PALO_XML"
  if [ -z "$(grep -o '<secret>' "$SSS_PALO_XML")" ]; then
    sed -i "s:</server>:</server>\\n  <secret>$SECRET</secret>:g;" "$SSS_PALO_XML"
  fi
fi

###############################################################################
## Upgrade config.xml and font_config.xml
## WARNING: Source of the error is the in the original .xml files
## These files should better be corrected in the repository and not here.
###############################################################################
# Change the micro charts extension config file to "font_config.xml" in config.xml (since version 5.1)
if [ -f "$SSS_CONFIG_XML" ]; then
  # The backup file $CONFIG_XML.bak will be created.
  sed -i.bak "s:<extension name=\"micro_charts\"[^>].*/>:<extension name=\"micro_charts\" config=\"etc/font_config.xml\"/>:g;" "$SSS_CONFIG_XML"
fi

# Rewrite the fonts path to /usr/share/fonts in font_config.xml (since version 5.1)
if [ -f "$SSS_FONT_XML" ]; then
  # The backup file $SSS_FONT_XML.bak will be created.
  sed -i.bak "s:<font_path[^>].*/>:<font_path font_path=\"/usr/share/fonts\" />:g;" "$SSS_FONT_XML"
fi

###############################################################################
## Copy the trial license, if there is not a license in place already
###############################################################################
if [ ! -f "$DATA_PATH/jedox.lic" ]; then
  if [ -f "$CURRENT_PATH/jedox.lic" ]; then
    cp "$CURRENT_PATH/jedox.lic" "$DATA_PATH/"
  fi
fi

# copy LICENSE.txt into installation path
cp -uf "$CURRENT_PATH/LICENSE.txt" "$INSTALL_PATH/"

###############################################################################
## Final steps
###############################################################################
sed -i "s:JEDOX_USER=jedoxuser:JEDOX_USER=$JEDOX_USER:g; s:JEDOX_GROUP=jedoxgroup:JEDOX_GROUP=$JEDOX_GROUP:g; s:JEDOX_VERSION=jedoxversion:JEDOX_VERSION=$VERSION:g" "$INSTALL_PATH/etc/jedoxenv.sh"
sed -i "s:INSTALL_PATH=/opt/jedox/ps:INSTALL_PATH=$INSTALL_PATH:g; s:ENABLE_SSL=0:ENABLE_SSL=$TLS_ONOFF:g" "$INSTALL_PATH/jedox-suite.sh"
sed -i "s:INSTALL_PATH=/opt/jedox/ps:INSTALL_PATH=$INSTALL_PATH:g" "$INSTALL_PATH/tomcat/jedox_tomcat.sh"

chown -R "$JEDOX_USER:$JEDOX_GROUP" "${INSTALL_PATH%/}"

echo
echo "The Jedox-Suite $VERSION is now configured."
echo "Start the Jedox-Suite services by running \"$INSTALL_PATH/jedox-suite.sh start\""
