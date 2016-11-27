# The ubuntu:latest tag points to the "latest LTS", since that's the version recommended for general use.
FROM ubuntu:latest
MAINTAINER Opnmind <opnmind@mailbox.org>

LABEL com.example.version="0.0.1-beta" \
	vendor="" \
	com.example.release-date="2016-11-27" \
	com.example.version.is-production=""

EXPOSE 80 7777 7775

# sudo docker build --force-rm -t opnmind/jedox .
# sudo docker tag <id> opnmind/jedox:5.1.SR5.01


# Additional Requirements for Linux
#
# https://knowledgebase.jedox.com/knowledgebase/additional-requirements-linux/
#
RUN apt-get update && \ 
	apt-get install -y apt-utils && \
	apt-get install -y libc6-i386 && \
	dpkg --add-architecture i386 && \
	apt-get update && \
	apt-get install -y \
		libfreetype6:i386 \
		libfontconfig1:i386 \
		libstdc++6:i386 \
		python-software-properties \
		software-properties-common \
		debconf-utils

# JDK 8 Oracle (JRE gibt es nicht als ppa)
#
# https://wiki.ubuntuusers.de/Java/Installation/Oracle_Java/Java_8/
#
RUN add-apt-repository -y ppa:webupd8team/java && \
	apt-get update && \
	echo "oracle-java8-installer shared/accepted-oracle-license-v1-1 select true" | debconf-set-selections && \
	apt-get install -y oracle-java8-installer && \
	apt install -y oracle-java8-set-default

# apt-get aufräumen
RUN rm -rf /var/lib/apt/lists/* && \
	rm -rf /opt/jedox

RUN wget http://www.jedox.com/de/download/jedox-5-1-premium-sr5?wpdmdl=25537 && \
	mv ./jedox-5-1-premium-sr5?wpdmdl=25537 ./jedox_5_1_sr5.tar && \
	tar -x ./jedox_5_1_sr5.tar


# Jedox kopieren und installieren
#ADD jedox_5_1_sr5.tar /tmp
# Annahme Lizenz
COPY .lic_agr_5.1 /tmp
COPY install.sh /tmp
RUN cd /tmp && \
	bash ./install.sh

# Konfigurieren von Jedox
#
#COPY ./config/olap.ini /opt/jedox/ps/Data/palo.ini
#COPY ./config/httpd.conf /opt/jedox/ps/etc/httpd/conf/httpd.conf
#COPY ./config/server.xml /opt/jedox/ps/tomcat/conf/server.xml
#COPY ./config/config.php /opt/jedox/ps/htdocs/app/etc/config.php
#COPY ./config/config.xml /opt/jedox/ps/core-Linux-i686/etc/config.xml
#COPY ./config/tomcat/config.xml /opt/jedox/ps/tomcat/webapps/etlserver/config/config.xml
#COPY ./config/palo_config.xml /opt/jedox/ps/core-Linux-i686/etc/palo_config.xml
#COPY ./config/php.ini /opt/jedox/ps/etc/php.ini
#COPY ./config/svs/php.ini /opt/jedox/ps/svs-Linux-i686/php.ini

#VOLUME [ "/opt/jedox/ps/Data/" ]

WORKDIR [ "/opt/jedox/ps" ]

# Abschliessendes starten der Palo DB
CMD [./jedox-suite.sh start]

















