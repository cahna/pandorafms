#
# Pandora FMS Server 
#
%define name        pandorafms_server
%define version	    3.0.0
%define release     1

Summary:            Pandora FMS Server
Name:               %{name}
Version:            %{version}
Release:            %{release}
License:            GPL
Vendor:             ArticaST <http://www.artica.es>
Source0:            %{name}-%{version}.tar.gz
URL:                http://www.pandorafms.com
Group:              System/Monitoring
Packager:           Manuel Arostegui <manuel@todo-linux.com>
Prefix:             /usr/share
BuildRoot:          %{_tmppath}/%{name}-buildroot
BuildArchitectures: noarch 
Requires(pre):      /usr/sbin/useradd
AutoReq:            0
Provides:           %{name}-%{version}
Requires:           perl-mail-sendmail perl-DBI perl-DBD-mysql perl-time-format 
Requires:           perl-mail-sendmail perl-netaddr-ip net-snmp
Requires:           nmap wmic sudo

%description
Pandora FMS is a monitoring system for big IT environments. It uses remote tests, or local agents to grab information. Pandora supports all standard OS (Linux, AIX, HP-UX, Solaris and Windows XP,2000/2003), and support multiple setups in HA enviroments.

%prep
rm -rf $RPM_BUILD_ROOT

%setup -q -n pandora_server

%build

%install
#Uncomment this if you build from other RPM system (fedora, opensuse != 11..)
#%define perl_version %(rpm -q --queryformat='%{VERSION}' perl)
#export perl_version=`rpm -q --queryformat='%{VERSION}' perl`

# Temporal hack for For SLES 11 only, warning
export perl_version=5.10.0
%define perl_version 5.10.0

rm -rf $RPM_BUILD_ROOT
mkdir -p $RPM_BUILD_ROOT/usr/bin/
mkdir -p $RPM_BUILD_ROOT/usr/local
mkdir -p $RPM_BUILD_ROOT/usr/local/bin
mkdir -p $RPM_BUILD_ROOT/usr/sbin/
mkdir -p $RPM_BUILD_ROOT/etc/init.d/
mkdir -p $RPM_BUILD_ROOT/etc/pandora/
mkdir -p $RPM_BUILD_ROOT/var/spool/pandora/data_in
mkdir -p $RPM_BUILD_ROOT/var/spool/pandora/data_in/conf
mkdir -p $RPM_BUILD_ROOT/var/spool/pandora/data_in/md5
mkdir -p $RPM_BUILD_ROOT/var/log/pandora/
mkdir -p $RPM_BUILD_ROOT%{prefix}/pandora_server/conf/
mkdir -p $RPM_BUILD_ROOT/usr/lib/perl5/site_perl/$perl_version/

# All binaries go to /usr/local/bin
cp -aRf bin/pandora_server $RPM_BUILD_ROOT/usr/local/bin/
cp -aRf bin/pandora_exec $RPM_BUILD_ROOT/usr/local/bin/
cp -aRf bin/tentacle_server $RPM_BUILD_ROOT/usr/local/bin/

cp -aRf conf/* $RPM_BUILD_ROOT%{prefix}/pandora_server/conf/
cp -aRf util $RPM_BUILD_ROOT%{prefix}/pandora_server/
cp -aRf lib/* $RPM_BUILD_ROOT/usr/lib/perl5/site_perl/$perl_version/
cp -aRf AUTHORS COPYING ChangeLog README $RPM_BUILD_ROOT%{prefix}/pandora_server/

cp -aRf util/pandora_server $RPM_BUILD_ROOT/etc/init.d/
cp -aRf util/tentacle_serverd $RPM_BUILD_ROOT/etc/init.d/

%clean
rm -fr $RPM_BUILD_ROOT
%pre
/usr/sbin/useradd -d %{prefix}/pandora -s /bin/false -M -g 0 pandora
exit 0

%post
chkconfig -s pandora_server on 
chkconfig -s tentacle_serverd on 
echo "/usr/share/pandora_server/util/pandora_db /etc/pandora/pandora_server.conf" > /etc/cron.daily/pandora_db
chmod 750 /etc/cron.daily/pandora_db
cp -aRf util/pandora_logrotate /etc/logrotate.d/pandora

if [ ! -d /etc/pandora ] ; then
   mkdir -p /etc/pandora
fi

if [ ! -e /etc/pandora/pandora_server.conf ] ; then
   ln -s /usr/share/pandora_server/conf/pandora_server.conf /etc/pandora/
   echo "Pandora FMS Server configuration is /etc/pandora/pandora_server.conf"
   echo "Pandora FMS Server main directory is %{prefix}/pandora_server/"
   echo "The manual can be reached at: man pandora or man pandora_server"
   echo "Pandora FMS Documentation is in: http://pandorafms.org"
   echo " "
fi

/etc/init.d/tentacle_serverd start

%preun
/etc/init.d/pandora_server stop &>/dev/null
/etc/init.d/tentacle_serverd stop &>/dev/null
chkconfig -d pandora_server
chkconfig -d tentacle_serverd

%files

%defattr(750,pandora,root)
/etc/init.d/pandora_server
/etc/init.d/tentacle_serverd

%defattr(755,pandora,root)
/usr/local/bin/pandora_exec
/usr/local/bin/pandora_server
/usr/local/bin/tentacle_server

%defattr(755,pandora,root)
/usr/lib/perl5/site_perl/%{perl_version}/PandoraFMS/
%{prefix}/pandora_server
/var/log/pandora

%defattr(770,pandora,www)
/var/spool/pandora

%defattr(750,pandora,root)
/etc/pandora

