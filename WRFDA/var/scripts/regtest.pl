#!/usr/bin/perl -w
# Author : Xin Zhang, MMM/NCAR, 8/17/2009
#

use strict;
use Term::ANSIColor;
use Time::HiRes qw(sleep gettimeofday);
use Time::localtime;
use Sys::Hostname;
use File::Path;
use File::Basename;
use File::Compare;
use IPC::Open2;
use Net::FTP;

# Start time:

my $Start_time;
my $tm = localtime;
$Start_time=sprintf "Begin : %02d:%02d:%02d-%04d/%02d/%02d\n",
        $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

# Constant variables
my $Exec = 1; # Use the current EXEs in WRFDA or not
my $SVN_REP = 'https://svn-wrf-model.cgd.ucar.edu/trunk';
my $Tester = getlogin();

# Local variables
my $Arch;
my $Compiler;
my $Project;
my $Source;
my $Queue;
my $Database;
my $Baseline;
my @Message;
my $Revision;
my $Par="";
my $Clear = `clear`;
my $Flush_Counter = 1;
my %Experiments ;
#   Sample %Experiments Structure: #####################
#   
#   %Experiments (
#                  cv3_guo => \%record (
#                                     index=> 1 
#                                     cpu_mpi=> 32
#                                     cpu_openmp=> 8
#                                     status=>"open"
#                                     paropt => { 
#                                                serial => {
#                                                           jobid => 89123
#                                                           status => "pending"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "ok"
#                                                          } 
#                                                smpar  => {
#                                                           jobid => 89123
#                                                           status => "done"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "ok"
#                                                          } 
#                                               }
#                                     )
#                  t44_liuz => \%record (
#                                     index=> 3 
#                                     cpu_mpi=> 16
#                                     cpu_openmp=> 4
#                                     status=>"open"
#                                     paropt => { 
#                                                serial => {
#                                                           jobid => 89123
#                                                           status => "pending"
#                                                           starttime => 8912312131.2
#                                                           endtime => 8912314560.2
#                                                           walltime => 2529.0
#                                                           compare => "diff"
#                                                          } 
#                                               }
#                                     )
#                 )
#########################################################
my %Compile_options;

# What's my hostname :

my $Host = hostname();

# Parse the task table:

while (<DATA>) {
     last if ( /^###/ && (keys %Experiments) > 0 );
     next if /^#/;
     if ( /^(\D)/ ) {
         ($Arch, $Source, $Compiler, $Project, $Queue, $Database, $Baseline) = 
               split /\s+/,$_;
     }

     if ( /^(\d)+/ && ($Host =~ /$Arch/i) ) {
          $_=~ m/(\d+) \s+ (\S+) \s+ (\S+) \s+ (\S+) \s+ (\S+)/x;
          my @tasks = split /\|/, $5;
          my %task_records;
          $task_records{$_} = {} for @tasks;
          my %record = (
               index => $1,
               cpu_mpi => $3,
               cpu_openmp => $4,
               status => "open",
               paropt => \%task_records
          );
          $Experiments{$2} = \%record;
          $Par = $5 unless ($Par =~ /$5/);
     }; 
}

printf "Finish parsing the table, the experiments are : \n";
printf "#INDEX   EXPERIMENT                   CPU_MPI    CPU_OPENMP   PAROPT\n";
printf "%-4d     %-27s  %-8d   %-13d"."%-10s "x(keys %{$Experiments{$_}{paropt}})."\n", 
     $Experiments{$_}{index}, $_, $Experiments{$_}{cpu_mpi},$Experiments{$_}{cpu_openmp},
         keys%{$Experiments{$_}{paropt}} for (keys %Experiments);

# Get the codes:

goto "SKIP_COMPILE" if $Exec;

if ( -e 'WRFDA' && -r 'WRFDA' ) {
     printf "Deleting the old WRFDA directory ... \n";
     rmtree ('WRFDA') or die "Can not rmtree WRFDA :$!\n";
}

if ($Source=~/SVN/i) {
     print "Getting the code from repository $SVN_REP to WRFDA...\n";
     open (my $fh,"-|","svn","co",$SVN_REP,"WRFDA")
          or die " Can't run svn export: $!\n";
     while (<$fh>) {
         $Revision = $1 if ( /revision \s+ (\d+)/x); 
     }
     close ($fh);
     printf "Revision %5d is exported to WRFDA.\n",$Revision;
} else {
     print "Getting the code from $Source to WRFDA...\n";
     ! system("tar", "xf", $Source) or die "Can not open $Source: $!\n",;
}

# Change the working directory to WRFDA:

chdir "WRFDA" or die "Cannot chdir to WRFDA: $!\n";

# Locate the compile options base on the $compiler:

my $pid = open2(my $readme, my $writeme, './configure','-d','wrfda');
print $writeme "1\n";
my @output = <$readme>;
waitpid($pid,0);
close ($readme);
close ($writeme);

# Add a slash before + in $Par :
$Par =~ s/\+/\\+/g;

foreach (@output) {
     if ( ($_=~ m/(\d+)\. .*$Compiler .* ($Par) .*/ix) && ! ($_=~/Cray/i) ) {
         $Compile_options{$1} = $2;
     }
}

printf "Found compilation option %6s for %2d.\n",$Compile_options{$_}, $_ for (sort keys %Compile_options);

die "WRFDA does not support compiler : $Compiler.\n" if ( (keys %Compile_options) == 0 );

# Set the envir. variables:

if ($Arch eq "be") {   # bluefire
    $ENV{CRTM} ='/blhome/wrfhelp/external/crtm/CRTM_02_03_09_REL_1_2/ibm_powerpc';
    $ENV{RTTOV} ='/blhome/wrfhelp/external/rttov/rttov87/ibm_powerpc';
    $ENV{NETCDF} ='/blhome/wrfhelp/external/netcdf/netcdf-3.6.1/ibm_powerpc';
}

if ($Arch eq "karri") {   # karri
    if ($Compiler=~/pgi/i) {   # PGI
        $ENV{CRTM} ='/karri/users/xinzhang/external/pgi_web/crtm';
        $ENV{RTTOV} ='/karri/users/xinzhang/external/pgi_web/rttov87';
        $ENV{NETCDF} ='/karri/users/xinzhang/external/pgi_web/netcdf-3.6.1';
        $ENV{PATH} ='/karri/users/xinzhang/external/mpi/mpich2-1.0.6p1/pgi_x86_64/bin:'.$ENV{PATH};
    }
    if ($Compiler=~/ifort/i) {   # INTEL
        $ENV{CRTM} ='/karri/users/xinzhang/external/intel_web/crtm';
        $ENV{RTTOV} ='/karri/users/xinzhang/external/intel_web/rttov87';
        $ENV{NETCDF} ='/karri/users/xinzhang/external/intel_web/netcdf-3.6.1';
        $ENV{PATH} ='/karri/users/xinzhang/external/mpi/mpich2-1.0.6p1/intel_x86_64/bin:'.$ENV{PATH};
    }
    if ($Compiler=~/gfortran/i) {   # GFORTRAN
        $ENV{CRTM} ='/karri/users/xinzhang/external/gfortran_web/crtm';
        $ENV{RTTOV} ='/karri/users/xinzhang/external/gfortran_web/rttov87';
        $ENV{NETCDF} ='/karri/users/xinzhang/external/gfortran_web/netcdf-3.6.1';
        $ENV{PATH} ='/karri/users/xinzhang/bin/gcc-4.3/bin:/karri/users/xinzhang/external/mpi/mpich2-1.0.6p1/gfortran_x86_64/bin:'.$ENV{PATH};
        $ENV{LD_LIBRARY_PATH} ='/karri/users/xinzhang/bin/gcc-4.3/lib64:'.$ENV{LD_LIBRARY_PATH};
        # the libc.so.6 is version 2.5 , can not support OpenMP yet.
        foreach my $key (keys %Compile_options) {
            if ($Compile_options{$key} =~/sm/i) {
                print "Note: shared-memory option $Compile_options{$key} was deleted for gfortran.\n";
                foreach my $name (keys %Experiments) {
                    foreach my $par (keys %{$Experiments{$name}{paropt}}) {
                        delete $Experiments{$name}{paropt}{$par} if $par eq $Compile_options{$key} ;
                        next ;
                    }
                }
                delete $Compile_options{$key};
            }
        }
    }
}

# Compile the code:

foreach my $option (sort keys %Compile_options) {
     # configure -d wrfda
     my $status = system ('./clean -a 1>/dev/null  2>/dev/null');
     die "clean -a exited with error $!\n" unless $status == 0;;
     $pid = open2($readme, $writeme, './configure','-d','wrfda');
     print $writeme "$option\n";
     @output = <$readme>;
     waitpid($pid,0);
     close ($readme);
     close ($writeme);

     if ( $Arch eq "be" ) {
         open FHCONF, "<configure.wrf" or die "Where is configure.wrf: $!\n"; 
         open FH, ">configure.wrf.new" or die "Cannot open configure.wrf.new: $!\n"; 
         while ($_ = <FHCONF>) { 
             $_ =~ s/-lmass -lmassv//;
             $_ =~ s/-DNATIVE_MASSV//;
             print FH $_;
         }
         close (FHCONF);
         close (FH);

         rename "configure.wrf.new", "configure.wrf";
     } elsif (($Arch eq "karri") && ($Compiler =~ /pgi/i) && ($Compile_options{$option} =~ /sm/i)) {
         open FHCONF, "<configure.wrf" or die "Where is configure.wrf: $!\n"; 
         open FH, ">configure.wrf.new" or die "Cannot open configure.wrf.new: $!\n"; 
         while ($_ = <FHCONF>) { 
             $_ =~ s/-mp/-mp=nonuma/;
             print FH $_;
         }
         close (FHCONF);
         close (FH);

         rename "configure.wrf.new", "configure.wrf";
     }

     # compile all_wrfvar
     printf "Compiling WRFDA with %10s for %6s ....\n", $Compiler, $Compile_options{$option};
     my $begin_time = gettimeofday();
     open FH, ">compile.log.$Compile_options{$option}" or die "Can not open file compile.log.$Compile_options{$option}.\n";
     $pid = open (PH, "./compile all_wrfvar 2>&1 |");
     while (<PH>) {
         print FH;
     }
     close (PH);
     close (FH);
     my $end_time = gettimeofday();

     # Check if the compilation is successful:

     my @exefiles = glob ("var/build/*.exe");

     die "The number of exe files is less than 31. \n" if (@exefiles < 31);

     foreach ( @exefiles ) {
         warn "The exe file $_ has problem. \n" unless -s ;
     }

     printf "Compilation of WRFDA with %10s for %6s is successful, using %4d seconds.\n", 
         $Compiler, $Compile_options{$option}, ($end_time - $begin_time);

     # Rename the da_wrfvar.exe:

     rename "var/build/da_wrfvar.exe","var/build/da_wrfvar.exe.$Compiler.$Compile_options{$option}";
}

# Back to the upper directory:

chdir ".." or die "Cannot chdir to .. : $!\n";

SKIP_COMPILE:

# Check the revision number:

$Revision = `svnversion WRFDA` unless defined $Revision;
chomp($Revision);

# Make working directory for each Expeirments:

foreach my $name (keys %Experiments) {

     # Make working directory:

     if ( -e $name && -r $name ) {
          rmtree ($name) or die "Can not rmtree $name :$!\n";
     }
     mkdir "$name", 0755 or warn "Cannot make $name directory: $!\n";
     next unless ( -e "$Database/$name" );

     # Symbolly link all files ;

     chdir "$name" or die "Cannot chdir to $name : $!\n";
     my @allfiles = glob ("$Database/$name/*");
     foreach (@allfiles) {
         symlink "$_", basename($_)
             or warn "Cannot symlink $_ to local directory: $!\n";
     }
     printf "The directory for %-30s is ready.\n",$name;

     # Back to the upper directory:

     chdir ".." or die "Cannot chdir to .. : $!\n";
}

# Submit the jobs for each task and check the status of each task recursively:

# How many experiments do we have ?

my $remain_exps = scalar keys %Experiments;  

#How many jobs do we have for each experiment ?

my %remain_jobs;
$remain_jobs{$_} = scalar keys %{$Experiments{$_}{paropt}} 
    for keys %Experiments;

# preset the the status of all jobs .

foreach my $name (keys %Experiments) {
    $Experiments{$name}{status} = "pending";
    foreach my $par (keys %{$Experiments{$name}{paropt}}) {
        $Experiments{$name}{paropt}{$par}{status} = "pending";
        $Experiments{$name}{paropt}{$par}{compare} = "--";
        $Experiments{$name}{paropt}{$par}{walltime} = 0;
    } 
} 

# Build cwordsh:

if ( $Arch ne "be" ) {
    my $ucarftp = Net::FTP->new("ftp.ucar.edu") 
        or die "Cannot connect to ftp.ucar.edu: $@";
    $ucarftp->login("anonymous",'-anonymous@')
        or die "Can not login ",$ucarftp->message;
    $ucarftp->cwd("/pub/mmm/xinzhang")
        or die "Cannot change working directory ", $ucarftp->message;
    $ucarftp->get("BUFRLIB.tar")
        or die "get failed ", $ucarftp->message;
    $ucarftp->get("cwordsh.tar")
        or die "get failed ", $ucarftp->message;
    $ucarftp->quit;
    
    if ( -e "bufr") {
          rmtree ("bufr") or die "Can not rmtree bufr :$!\n";
    }
    mkdir "bufr", 0755 or warn "Cannot make bufr directory: $!\n";
    chdir "bufr" or die "Cannot change directory to bufr: $!\n";
    system("tar","xf","../BUFRLIB.tar");

    my @sfc;
    my @scc;

    open FHCONF, "<../WRFDA/configure.wrf" or die "Where is configure.wrf: $!\n"; 
    while (my $line = <FHCONF>) { 
        @sfc = split /\s+=\s+/,$line if $line=~/^SFC/;
        @scc = split /\s+=\s+/,$line if $line=~/^SCC/;
    }
    close (FHCONF);
    chomp($sfc[1]);
    chomp($scc[1]);
    system($sfc[1],"-c",$_) for glob("*.f");
    system($sfc[1],"-c",$_) for glob("*.F");
    system($scc[1],"-c",$_) for glob("*.c");
    system("ar","cr","libbufr.a",$_) for glob("*.o");
    die "libbufr.a was not created.\n" if !-f "libbufr.a";
    system("tar","xf","../cwordsh.tar");
    system($sfc[1],"-o","cwordsh.x","cwordsh.f","libbufr.a");
    die "cwordsh.x was not created.\n" if !-f "cwordsh.x";
    exit;
    chdir ".." or die "Cannot change directory to ..: $!\n";
}


# Initail Status:

&flush_status ();

# submit job:

($Arch eq "be") ? &submit_job_be : &submit_job ;

# End time:

my $End_time;
$tm = localtime;
$End_time=sprintf "End   : %02d:%02d:%02d-%04d/%02d/%02d\n",
        $tm->hour, $tm->min, $tm->sec, $tm->year+1900, $tm->mon+1, $tm->mday;

# Create the webpage:

&create_webpage ();

# Mail out summary:

open (SENDMAIL, "|/usr/sbin/sendmail -oi -t -odq")
       or die "Can't fork for sendmail: $!\n";

print SENDMAIL  "From: $Tester\n";
print SENDMAIL  "To: $Tester\@ucar.edu"."\n";
print SENDMAIL  "Subject: Regression test summary\n";

print $Clear;
print @Message;
print SENDMAIL $Start_time."\n";
print SENDMAIL "Source :",$Source."\n";
print SENDMAIL "Revision :",$Revision."\n";
print SENDMAIL "Tester :",$Tester."\n";
print SENDMAIL "Machine name :",$Host."\n";
print SENDMAIL "Compiler :",$Compiler."\n";
print SENDMAIL "Baseline :",$Baseline."\n";
print SENDMAIL @Message;
print SENDMAIL $End_time."\n";

close(SENDMAIL);

#
#
#

sub create_webpage {

    open WEBH, ">summary.html" or
        die "Can not open a summary.html for write: $!\n";

    print WEBH '<html>'."\n";
    print WEBH '<body>'."\n";

    print WEBH '<p>'."Regression Test Summary:".'</p>'."\n";
    print WEBH '<ul>'."\n";
    print WEBH '<li>'.$Start_time.'</li>'."\n";
    print WEBH '<li>'."Source : $Source".'</li>'."\n";
    print WEBH '<li>'."Revision : $Revision".'</li>'."\n";
    print WEBH '<li>'."Tester : $Tester".'</li>'."\n";
    print WEBH '<li>'."Machine name : $Host".'</li>'."\n";
    print WEBH '<li>'."Compiler : $Compiler".'</li>'."\n";
    print WEBH '<li>'."Baseline : $Baseline".'</li>'."\n";
    print WEBH '<li>'.$End_time.'</li>'."\n";
    print WEBH '</ul>'."\n";

    print WEBH '<table border="1">'."\n";
#   print WEBH '<caption>Regression Test Summary</caption>'."\n";
    print WEBH '<tr>'."\n";
    print WEBH '<th>EXPERIMENT</th>'."\n";
    print WEBH '<th>PAROPT</th>'."\n";
    print WEBH '<th>CPU_MPI</th>'."\n";
    print WEBH '<th>CPU_OMP</th>'."\n";
    print WEBH '<th>STATUS</th>'."\n";
    print WEBH '<th>WALLTIME(S)</th>'."\n";
    print WEBH '<th>COMPARE</th>'."\n";
    print WEBH '</tr>'."\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            print WEBH '<tr>'."\n";
            print WEBH '<td>'.$name.'</td>'."\n";
            print WEBH '<td>'.$par.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{cpu_mpi}.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{cpu_openmp}.'</td>'."\n";
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{status}.'</td>'."\n";
            printf WEBH '<td>'."%7.1f".'</td>'."\n",
                         $Experiments{$name}{paropt}{$par}{walltime};
            print WEBH '<td>'.$Experiments{$name}{paropt}{$par}{compare}.'</td>'."\n";
            print WEBH '</tr>'."\n";
        }
    }
            print WEBH '</table>'."\n"; 

    print WEBH '</body>'."\n";
    print WEBH '</html>'."\n";

    close (WEBH);

# Send the summary to internet:

    !system "scp","-oPort=2222", "summary.html",
        "wrfhelp\@box.mmm.ucar.edu:/web/htdocs/people/wrfhelp/wrfvar/results/index.html" or
        die "can not upload the summary.html: $!\n";
}

sub refresh_status {

    my @mes; 

    push @mes, "Experiment                  Paropt      CPU_MPI  CPU_OMP  Status    Walltime(s)    Compare\n";
    push @mes, "==========================================================================================\n";

    foreach my $name (sort keys %Experiments) {
        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
            push @mes, sprintf "%-28s%-12s%-9d%-9d%-10s%-15d%-7s\n", 
                    $name, $par, $Experiments{$name}{cpu_mpi}, 
                    $Experiments{$name}{cpu_openmp}, 
                    $Experiments{$name}{paropt}{$par}{status},
                    $Experiments{$name}{paropt}{$par}{walltime},
                    $Experiments{$name}{paropt}{$par}{compare};
        }
    }

    push @mes, "==========================================================================================\n";
    return @mes;
}

sub new_job {
     
     my ($nam, $com, $par, $cpun, $cpum) = @_;

     # Enter into the experiment working directory:

     chdir "$nam" or die "Cannot chdir to $nam : $!\n";

     # unblk and block bufr files if there are:

     foreach my $bufr_file (glob("*.bufr")) {
         `cwordsh.sh unblk $bufr_file $bufr_file.unblk >& /dev/null`;
         `cwordsh.sh block $bufr_file.unblk $bufr_file.block >& /dev/null`;
         unlink "$bufr_file.unblk";
         unlink $bufr_file;
         symlink "$bufr_file.block",$bufr_file or
              die "Cannot link $bufr_file.block to $bufr_file: $!\n";
     }
     
     # Submit the job :

     delete $ENV{OMP_NUM_THREADS};
     $ENV{OMP_NUM_THREADS}=$cpum if ($par=~/sm/i);

     if ($par=~/dm/i) { 
         system ("mpdallexit>/dev/null");
         system ("mpd&");
         sleep (0.1);
         `mpirun -np $cpun ../WRFDA/var/build/da_wrfvar.exe.$com.$par`;
     } else {
         `../WRFDA/var/build/da_wrfvar.exe.$com.$par > print.out.$nam.$par`; 
     }

     rename "rsl.out.0000", "print.out.$nam.$par" if (($par=~/dm/i) && (-f "rsl.out.0000"));

     # Back to the upper directory:

     chdir ".." or die "Cannot chdir to .. : $!\n";

     return (-f "$nam/wrfvar_output") ? 1 : undef;
}

sub new_job_be {
     
     my ($nam, $com, $par, $cpun, $cpum) = @_;

     # Enter into the experiment working directory:

     chdir "$nam" or die "Cannot chdir to $nam : $!\n";

     # Generate the LSF job script:
     unlink "job_${nam}_$par.csh" if -e 'job_$nam_$par.csh';
     open FH, ">job_${nam}_$par.csh" or die "Can not open a job_${nam}_$par.csh to write. $! \n";

     print FH '#!/usr/bin/csh'."\n";
     print FH '#',"\n";
     print FH '# LSF batch script'."\n";
     print FH '#'."\n";
     print FH "#BSUB -J $nam"."\n";
     print FH "#BSUB -q $Queue"."\n";
     printf FH "#BSUB -n %-3d"."\n",($par eq 'dmpar' || $par eq 'dm+sm') ?
                                    $cpun: 1;
     print FH "#BSUB -o job_${nam}_$par.output"."\n";
     print FH "#BSUB -e job_${nam}_$par.error"."\n";
     print FH "#BSUB -W 360"."\n";
     print FH "#BSUB -P $Project"."\n";
     printf FH "#BSUB -R span[ptile=%d]"."\n", ($par eq 'serial' || $par eq 'smpar') ?
                                                1 : 32;
     print FH "\n";
     print FH ( $par eq 'smpar' || $par eq 'dm+sm') ? 
         "setenv OMP_NUM_THREADS $cpum\n" :"\n"; 
     print FH ( $par eq 'smpar' || $par eq 'dm+sm') ? 
         'setenv XLSMPOPTS "startproc=0:stride=2:stack=128000000"'."\n" :"\n"; 
     print FH ($par eq 'serial' || $par eq 'smpar') ? 
         "../WRFDA/var/build/da_wrfvar.exe.$com.$par\n" : 
         "mpirun.lsf ../WRFDA/var/build/da_wrfvar.exe.$com.$par\n";
     print FH "\n";
     print FH 'RC=$?';

     close (FH);

     # Submit the job :

     my $feedback = ` bsub < job_${nam}_$par.csh 2>/dev/null `;

     # Back to the upper directory:

     chdir ".." or die "Cannot chdir to .. : $!\n";

     # pick the job id :

     if ($feedback =~ m/.*<(\d+)>/) {;
          # printf "Task %-30s 's jobid is %10d \n",$nam,$1;
         return $1;
     } else {
         print color("red"), colored("Fail to submit task for $nam\n", "blink"), color("reset");
         return undef;
     };


}

sub compare2baseline {
   
     my ($name, $par) = @_;

     my @output = `WRFDA/var/build/diffwrf $name/wrfvar_output.$name.$par $Baseline/wrfvar_output.$name`;
     
     my $found = 0;

     foreach (@output) {
         
         if (/pntwise max/) {
             $found = 1 ;
             next;
         }
        
         next unless $found;

         my @values = split /\s+/, $_;

         return 1 unless ($values[4] == $values[5]) ;   #compare RMS (1) and RMS (2) , return immediately once diff found.
     }
     
     return 0;        # All the same.

}

sub flush_status {

    @Message = &refresh_status ();   # Update the Message
    print $Clear; 
    # print $Flush_Counter++ ,"\n";
    print @Message;

}

sub submit_job {

    foreach my $name (keys %Experiments) {

        foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
   
            $Experiments{$name}{paropt}{$par}{starttime} = gettimeofday();
            $Experiments{$name}{paropt}{$par}{status} = "running";
            &flush_status (); # refresh the status
            my $rc = &new_job ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                $Experiments{$name}{cpu_openmp} );
            if (defined $rc) { 
                $Experiments{$name}{paropt}{$par}{endtime} = gettimeofday(); # set the end time for this job.
                $Experiments{$name}{paropt}{$par}{walltime} = 
                    $Experiments{$name}{paropt}{$par}{endtime} - $Experiments{$name}{paropt}{$par}{starttime};
                printf "%-10s Job for %-30s was finished within %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};
            } else {
                $Experiments{$name}{paropt}{$par}{status} = sprintf colored("%-10s",'red on_yellow blink'),"error";
                $Experiments{$name}{paropt}{$par}{compare} = sprintf colored("%-10s",'red on_yellow blink'), "diff";
                next;   # Can not submit this job.
            }

            $Experiments{$name}{paropt}{$par}{status} = "done";

            # Wrap-up this job:

            rename "$name/wrfvar_output", "$name/wrfvar_output.$name.$par";

            # Compare the wrfvar_output with the BASELINE:

            unless ($Baseline =~ /none/i) {
                if (compare ("$name/wrfvar_output.$name.$par","$Baseline/wrfvar_output.$name") == 0) {
                    $Experiments{$name}{paropt}{$par}{compare} = "ok";
                } else {
                    $Experiments{$name}{paropt}{$par}{compare} = &compare2baseline ($name,$par) ? 
                        sprintf colored("%-10s",'red on_yellow blink'),"diff" : "ok";
                }
            }

        }

    }
    &flush_status (); # refresh the status
}

sub submit_job_be {

    while ($remain_exps > 0) {    # cycling until no more experiments remain

         foreach my $name (keys %Experiments) {

             next if ($Experiments{$name}{status} eq "done") ;  # skip this experiment if it is done.
         
             foreach my $par (sort keys %{$Experiments{$name}{paropt}}) {
   
                 next if ( $Experiments{$name}{paropt}{$par}{status} eq "done"  ||      # go to next job if it is done already..
                           $Experiments{$name}{paropt}{$par}{status} eq "killed" ||
                           $Experiments{$name}{paropt}{$par}{status} eq "error" );

                 unless ( defined $Experiments{$name}{paropt}{$par}{jobid} ) {      #  to be submitted .

                     next if $Experiments{$name}{status} eq "close";      #  skip if this experiment close to submit job .

                     my $rc = &new_job_be ( $name, $Compiler, $par, $Experiments{$name}{cpu_mpi},
                                         $Experiments{$name}{cpu_openmp} );
                     if (defined $rc) { 
                         $Experiments{$name}{paropt}{$par}{jobid} = $rc ;    # assign the jobid.
                         delete $Experiments{$name}{paropt}{$par}{starttime}; # reset the timer for this job.
                         delete $Experiments{$name}{paropt}{$par}{endtime}; 
                         $Experiments{$name}{status} = "close";
                         printf "%-10s Job for %-30s was submitted with jobid: %10d \n", $par, $name, $rc;
                     } else {
                         $Experiments{$name}{paropt}{$par}{status} = sprintf colored("%-10s",'red on_yellow blink'),"error";
                         $Experiments{$name}{paropt}{$par}{compare} = sprintf colored("%-10s",'red on_yellow blink'), "diff";
                         $remain_jobs{$name} -- ;
                         next;   # Can not submit this job.
                     }
                 } 
     
                 # Job is still in queue.


                 my $feedback = `bjobs $Experiments{$name}{paropt}{$par}{jobid}`;
                 if ( $feedback =~ m/RUN/ ) {; # Still running 
                     unless (defined $Experiments{$name}{paropt}{$par}{starttime}) { #set the start time when we first find it is running.
                         $Experiments{$name}{paropt}{$par}{status} = "running";
                         $Experiments{$name}{paropt}{$par}{starttime} = gettimeofday();
                         &flush_status (); # refresh the status
                     }
                     next;
                 } elsif ( $feedback =~ m/PEND/ ) { # Still Pending
                     next;
                 }

                 # Job is finished.

                 $Experiments{$name}{paropt}{$par}{endtime} = gettimeofday(); # set the end time for this job.
    
                 unless (defined $Experiments{$name}{paropt}{$par}{starttime}) { # This job was exit mysteriously: killed or time out.
                     printf "Task %-30s is killed .\n", $name; 
                     $Experiments{$name}{paropt}{$par}{compare} = sprintf colored("%-10s",'red on_yellow blink'),"unknown";
                     delete $Experiments{$name}{paropt}{$par}{jobid};       # Delete the jobid.
                     $remain_jobs{$name} -- ;                               # Delete the count of jobs for this experiment.
                     $Experiments{$name}{paropt}{$par}{status} = sprintf colored("%-10s",'red on_yellow blink'),"killed";
                 } else {
                     $Experiments{$name}{paropt}{$par}{walltime} = 
                          $Experiments{$name}{paropt}{$par}{endtime} - $Experiments{$name}{paropt}{$par}{starttime};
                     printf "%-10s Job for %-30s was finished within %5d seconds. \n", $par, $name, $Experiments{$name}{paropt}{$par}{walltime};

                     delete $Experiments{$name}{paropt}{$par}{jobid};       # Delete the jobid.
                     $remain_jobs{$name} -- ;                               # Delete the count of jobs for this experiment.
                     $Experiments{$name}{paropt}{$par}{status} = "done";    # Done this job.

                     # Wrap-up this job:

                     rename "$name/wrfvar_output", "$name/wrfvar_output.$name.$par";

                     # Compare the wrfvar_output with the BASELINE:

                     unless ($Baseline =~ /none/i) {
                         if (compare ("$name/wrfvar_output.$name.$par","$Baseline/wrfvar_output.$name") == 0) {
                             $Experiments{$name}{paropt}{$par}{compare} = "ok";
                         } else {
                             $Experiments{$name}{paropt}{$par}{compare} = &compare2baseline ($name,$par) ? 
                                 sprintf colored("%-10s",'red on_yellow blink'),"diff" : "ok";
                         }
                     }
                 }

                 if ($remain_jobs{$name} == 0) {                        # if all jobs in this experiment are done, done this experiment.
                     $Experiments{$name}{status} = "done";
                     $remain_exps -- ; 
                 } else {
                     $Experiments{$name}{status} = "open";              # Since this experiment is not done yet, open to submit job.
                 }

                 &flush_status ();
             }

         }
         sleep (2.); 
    }
}
__DATA__
###########################################################################################
#ARCH      SOURCE     COMPILER    PROJECT   QUEUE   DATABASE                             BASELINE
be         /mmm/users/xinzhang/wrfda.tar        XLF         64000510  share /mmm/users/xinzhang/WRFDA-data-EM    /ptmp/xinzhang/BASELINE
#INDEX   EXPERIMENT                  CPU     OPENMP       PAROPT
#1        tutorial_xinzhang           16      16           serial|smpar|dmpar
2        cv3_guo                     16      16           serial|smpar|dmpar
3        t44_liuz                    16      16           serial|smpar|dmpar
#4        radar_meixu                 16      16           serial|smpar|dmpar
5        cwb_ascii                   16      16           serial|smpar|dmpar
#6        afwa_t7_ssmi                16      16           serial|smpar|dmpar
#7        t44_prepbufr                16      16           serial|smpar|dmpar
#8        ASR_prepbufr                16      16           serial|smpar|dmpar
#9        cwb_ascii_outerloop_rizvi   16      16           serial|smpar|dmpar
#10       sfc_assi_2_outerloop_guo    16      16           serial|smpar|dmpar
###########################################################################################
#ARCH      SOURCE     COMPILER    PROJECT   QUEUE   DATABASE                             BASELINE
karri      wrfda.tar        ifort         64000420  share   /karri/users/xinzhang/regtest/WRFDA-data-EM    none
#INDEX   EXPERIMENT                  CPU     OPENMP       PAROPT
1        tutorial_xinzhang           4       4            serial|smpar|dmpar
#2        cv3_guo                     4       4            serial|smpar|dmpar
#3        t44_liuz                    4       4            serial|smpar|dmpar
#4        radar_meixu                 4       4            serial|smpar|dmpar
#5        cwb_ascii                   4       4            serial|smpar|dmpar
#6        afwa_t7_ssmi                4       4            serial|smpar|dmpar
#7        t44_prepbufr                4       4            serial|smpar|dmpar
#8        ASR_prepbufr                4       4            serial|smpar|dmpar
#9        cwb_ascii_outerloop_rizvi   4       4            serial|smpar|dmpar
#10       sfc_assi_2_outerloop_guo    4       4            serial|smpar|dmpar
###########################################################################################