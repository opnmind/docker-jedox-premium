
# sudo docker build --force-rm -t opnmind/jedox .
# sudo docker tag <id> opnmind/jedox:7.0.SR2
# docker exec -ti 313b84534fbf /bin/bash
# docker run --privileged -p 8080:80 -p 7777:7777 -ti opnmind/jedox /bin/bash
# service docker restart # Netzwerkprobleme

# The centos7:latest tag points to the "latest LTS", since that's the version recommended for general use.
FROM centos:7
MAINTAINER Opnmind <opnmind@mailbox.org>

LABEL com.example.version="1.0.0" \
	vendor="" \
	com.example.release-date="2017-09-15" \
	com.example.version.is-production=""

EXPOSE 80 7777 7779 7775 443

# Automatically disabled Acquire::http::Pipeline-Depth
#RUN echo "Acquire::http::Pipeline-Depth \"False\"" >> /etc/apt/apt.conf
#RUN cat /etc/apt/apt.conf

# Additional Requirements for Linux
#
# https://knowledgebase.jedox.com/knowledgebase/additional-requirements-linux/
#
RUN yum update -y
RUN	yum install -y findutils \
	wget \
	git \
	net-tools \
	nano \
	mc \
	boost-thread \
	boost-regex \
	gperftools-libs \
	glibc.i686 \
	glibc-devel.i686 \
	libfreetype6.i686 \
	gcc-g++.i686 \
	libstdc++-devel.i686

# JDK 8 Oracle (JRE gibt es nicht als ppa)
#
# https://wiki.ubuntuusers.de/Java/Installation/Oracle_Java/Java_8/
#
#COPY ./jdk-8u144-linux-x64.rpm /tmp
#RUN rpm -Uvh /tmp/jdk-8u144-linux-x64.rpm && \
#	alternatives --install /usr/bin/java java /usr/java/latest/jre/bin/java 20000 && \
#	alternatives --install /usr/bin/javaws javaws /usr/java/latest/jre/bin/javaws 20000 && \
#	alternatives --install /usr/bin/javac javac /usr/java/latest/bin/javac 20000 && \
#	alternatives --install /usr/bin/jar jar /usr/java/latest/bin/jar 20000

# aufräumen
RUN rm -rf /opt/jedox
#RUN sestatus
#RUN echo 0 > /sys/fs/selinux/enforce

# Jedox kopieren und installieren
COPY jedox_7_0_sr2.tar /tmp
RUN	cd /tmp && \
	tar -vxf ./jedox_7_0_sr2.tar

# Annahme Lizenz
COPY .lic_agr_7.0 /tmp
RUN cd /tmp && \	
	bash ./install.sh

WORKDIR /opt/jedox/ps

# Docker fix container exit 0
# add > tail -f $INSTALL_PATH/log/*.log $INSTALL_PATH/log/tomcat/*.log
COPY 0002-fixed-docker-exit-0.patch /tmp
RUN git apply /tmp/0002-fixed-docker-exit-0.patch

#RUN chroot /opt/jedox/ps /bin/bash && \
#	yum update -y java-1.8.0-openjdk && \
#	exit

RUN yum clean all

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

VOLUME /opt/jedox/ps/Data
VOLUME /opt/jedox/ps/log
VOLUME /opt/jedox/ps/storage
VOLUME /opt/jedox/ps/tomcat/webapps/etlserver/data

# Abschliessendes starten der Palo DB
#CMD [ "/opt/jedox/ps/jedox-suite.sh", "start" ]
#ENTRYPOINT [ "/opt/jedox/ps/jedox-suite.sh", "start" ]
