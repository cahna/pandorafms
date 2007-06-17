#!/usr/bin/perl
##########################################################################
# Pandora Data Server
##########################################################################
# Copyright (c) 2004-2007 Sancho Lerena, slerena@gmail.com
# Copyright (c) 2005-2006 Artica Soluciones Tecnologicas S.L
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 2
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##########################################################################

# Includes list
use strict;
use warnings;

use XML::Simple;                	# Useful XML functions
use Digest::MD5;                	# MD5 generation
use Time::Local;                	# DateTime basic manipulation
use DBI;                            # DB interface with MySQL
use Date::Manip;                	# Needed to manipulate DateTime formats of input, output and compare
use File::Copy;                     # Needed to manipulate files
use threads;
use threads::shared;

# Pandora Modules
use PandoraFMS::Config;
use PandoraFMS::Tools;
use PandoraFMS::DB;

# FLUSH in each IO, only for DEBUG, very slow !
$| = 0;

my %pa_config; 

# Init main loop
pandora_init(\%pa_config,"Pandora FMS Data Server");

# Read config file for Global variables
pandora_loadconfig (\%pa_config,0);

# Audit server starting
pandora_audit (\%pa_config, "Pandora FMS data server Daemon starting", "SYSTEM", "System");

# BE CAREFUL, if you daemonize, you need to launch threads BEFORE daemonizing.
if ($pa_config{"daemon"} eq "1" ){
	&daemonize;
}

# KeepAlive checks for Agents, only for master servers, in separate thread
threads->new( \&pandora_keepalived, \%pa_config);

# Module processor subsystem
pandora_dataserver (\%pa_config);

##########################################################################
# Main loop
##########################################################################

sub pandora_dataserver {
	my $pa_config = $_[0];
	my $file_data;
	my $file_md5;
	my @file_list;
	my $onefile; # Each item of incoming directory 
	my $agent_filename;
	my $dbh = DBI->connect("DBI:mysql:$pa_config->{'dbname'}:$pa_config->{'dbhost'}:3306",$pa_config->{"dbuser"}, $pa_config->{"dbpass"},{ RaiseError => 1, AutoCommit => 1 });

	while ( 1 ) { # Pandora module processor main loop
		opendir(DIR, $pa_config->{'incomingdir'} ) or die "[FATAL] Cannot open Incoming data directory at $pa_config->{'incomingdir'}: $!";
 		while (defined($onefile = readdir(DIR))){
   			push @file_list,$onefile; 	# Push in a stack all directory entries for this loop
 		}
        while (defined($onefile = pop @file_list)) {	# Begin to process files
		    threads->yield;
            $file_data = "$pa_config->{'incomingdir'}/$onefile";
            next if $onefile =~ /^\.\.?$/;     # Skip . and .. directory
            
            # First filter any file that doesnt like ".data"
            if ( $onefile =~ /([\-\:\;\.\,\_\s\a\*\=\(\)a-zA-Z0-9]*).data\z/ ) {
   				$agent_filename = $1;
   				$file_md5 = "$pa_config->{'incomingdir'}/$agent_filename.checksum";
	            # If check is disabled, ignore if file_md5 exists
                if (( -e $file_md5 ) or ($pa_config->{'pandora_check'} == 0)){
                    # Verify integrity
                    my $check_result;
					$check_result = md5check ($file_data,$file_md5);
					if (($pa_config->{'pandora_check'} == 0) || ($check_result == 1)){
						# PERL cannot "free" memory on user demmand, so 
						# we are declaring $config hash reference in inner loop
						# to force PERL system to realloc memory in each loop.
						# In Pandora 1.1 in "standard" PERL Implementations, we could
						# have a memory leak problem. This is solved now :-)
						# Source : http://www.rocketaware.com/perl/perlfaq3/
                        # Procesa_Datos its the main function to process datafile
						my $config; # Hash Reference, used to store XML data
                        # But first we needed to verify integrity of data file
                        if ($pa_config->{'pandora_check'} == 1){
							logger ($pa_config, "Integrity of Datafile using MD5 is verified: $file_data",3);
						}
                        eval { # XML Processing error catching procedure. Critical due XML was no validated
                            logger ($pa_config, "Ready to parse $file_data",4);
                            $config = XMLin($file_data, forcearray=>'module');
                        };
                        if ($@) {
                            logger ($pa_config, "[ERROR] Error processing XML contents in $file_data",0);
                            copy ($file_data,$file_data."_BADXML");
                            if (($pa_config->{'pandora_check'} == 1) && ( -e $file_md5 )) {
							    copy ($file_md5,$file_md5."_BADCHECKSUM");
						    }
                        }
						procesa_datos ($pa_config, $config, $dbh); 
						undef $config;
                        # If _everything_ its ok..
						# delete files
                                        	unlink ($file_data);
                                        	if ( -e $file_md5 ) {
							unlink ($file_md5);
						}
                    } else { # md5 check fails
     					logger ( $pa_config, "[ERROR] MD5 Checksum failed! for $file_data",0);
						# delete files
                        unlink ($file_data);
                        if ( -e $file_md5 ) {
							unlink ($file_md5);
						}
    				}
   				} # No checksum file, ignore file
            }
        }
        closedir(DIR);
		threads->yield;
        sleep $pa_config->{"server_threshold"};
	}
} # End of main loop function

##########################################################################
## SUB pandora_keepalived
## Pandora Keepalive alert daemon subsystem
##########################################################################

sub pandora_keepalived {
	my $pa_config = $_[0];
	my $dbh = DBI->connect("DBI:mysql:$pa_config->{'dbname'}:$pa_config->{'dbhost'}:3306",$pa_config->{"dbuser"}, $pa_config->{"dbpass"},{ RaiseError => 1, AutoCommit => 1 });
	while ( 1 ){
		sleep $pa_config->{"server_threshold"};
		threads->yield;
		keep_alive_check ($pa_config, $dbh);
		pandora_serverkeepaliver ($pa_config, 0, $dbh); # 0 for dataserver
	}
}


##########################################################################
## SUB keep_alive_check  ()
## Calculate a global keep alive check for agents without data and an alert defined 
##########################################################################

sub keep_alive_check {
    # Search of any defined alert for any agent/module table entry
	my $pa_config = $_[0];
	my $dbh = $_[1];
    
	my $timestamp = &UnixDate ("today", "%Y-%m-%d %H:%M:%S");
    my $query_idag = "SELECT tagente_modulo.id_agente_modulo, tagente_modulo.id_tipo_modulo, tagente_modulo.nombre, tagente_estado.datos FROM tagente_modulo, talerta_agente_modulo, tagente_estado WHERE tagente_modulo.id_agente_modulo = talerta_agente_modulo.id_agente_modulo AND talerta_agente_modulo.disable = 0 AND tagente_modulo.id_tipo_modulo = -1 AND tagente_estado.id_agente_modulo = tagente_modulo.id_agente_modulo";
    my $s_idag = $dbh->prepare($query_idag);
    $s_idag ->execute;

	# data needed in loop (we'll reuse it)
    my @data;
	my $nombre_agente;
	my $id_agente_modulo;
	my $tipo_modulo;
	my $nombre_modulo;
	my $datos;

	if ($s_idag->rows != 0) {
		while (@data = $s_idag->fetchrow_array()) {
			threads->yield;
			$id_agente_modulo = $data[0];	
			$nombre_agente = dame_nombreagente_agentemodulo ($pa_config, $id_agente_modulo, $dbh);
			$nombre_modulo = $data[2];
			$datos = $data[3];
			$tipo_modulo = $data[1];
			pandora_calcula_alerta ($pa_config, $timestamp, $nombre_agente, $tipo_modulo, $nombre_modulo, $datos, $dbh);
		}
	} 
	$s_idag->finish();
}

##########################################################################
## SUB procesa_datos (param_1)
## Process data packet (XML file)
##########################################################################
## param_1 : XML datafile name

sub procesa_datos {
   	my $pa_config = $_[0];
    	my $datos = $_[1]; 
	my $dbh = $_[2];

	my $tipo_modulo;
    my $agent_name; 
	my $timestamp;
    my $interval; 
	my $os_version;
    my $agent_version;
    my $id_agente;
    my $module_name;
    
	$agent_name = $datos->{'agent_name'};
	$timestamp = $datos->{'timestamp'};
	$agent_version = $datos->{'version'};
	$interval = $datos->{'interval'};
	$os_version = $datos->{'os_version'};
  
  	# Set default interval if not defined in agent (This is very very odd whatever!).
   	if (!defined($interval)){
		$interval = 300;
	}

	# Check for parameteres, not all version agents gives the same parameters !
	if (length($interval) == 0){
       $interval = -1; # No update for interval !
    }
   
   	if ((!defined ($os_version)) || (length($os_version) == 0)){
		$os_version = "N/A";
	}
  
	if (defined $agent_name){
		$id_agente = dame_agente_id($pa_config,$agent_name,$dbh);
		if ($id_agente > 0) {
			pandora_lastagentcontact ($pa_config, $timestamp, $agent_name, $os_version, $agent_version, $interval, $dbh);
			foreach my $part(@{$datos->{module}}) {
				$tipo_modulo = $part->{type}->[0];
				$module_name = $part->{name}->[0];
                if (defined($module_name)){ # Skip modules without names 
				    logger($pa_config, "Processing module Name ( $module_name ) type ( $tipo_modulo ) for agent ( $agent_name )", 5);
				    if ($tipo_modulo eq 'generic_data') {
					    module_generic_data ($pa_config, $part, $timestamp, $agent_name, "generic_data", $dbh);
				    }
				    elsif ($tipo_modulo eq 'generic_data_inc') {
					    module_generic_data_inc ($pa_config, $part, $timestamp, $agent_name,"generic_data_inc", $dbh);
				    }
				    elsif ($tipo_modulo eq 'generic_data_string') {
					    module_generic_data_string ($pa_config, $part, $timestamp, $agent_name,"generic_data_string", $dbh);
				    }
				    elsif ($tipo_modulo eq 'generic_proc') {
					    module_generic_proc ($pa_config, $part, $timestamp, $agent_name, "generic_proc", $dbh);
				    }
				    else {
					    logger($pa_config, "ERROR: Received data from an unknown module ($tipo_modulo)", 2);
				    }
                }            
			}
		} else {
			logger($pa_config, "ERROR: There is no agent defined with name $agent_name ($id_agente)", 2);
		}
	} else {
		logger($pa_config, "ERROR: Received data from an unknown agent", 1);
	}
}
