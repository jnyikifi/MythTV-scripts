#!/usr/bin/perl

######################################################################################################
######################################################################################################
###                                                                                                ###
### User Job for MythTV                                                                            ###
### Mythtranscode + cutlist + encode to x264 with handbrake (mkv)                                  ###
###                                                                                                ###
### Start this script with these parameters                                                        ###
###                                                                                                ###
### ../myth_make_x264.pl --chanid=%CHANID% --starttime=%STARTTIME% --directory=%DIR% --file=%FILE% ###
###                                                                                                ###
######################################################################################################
######################################################################################################

use utf8;

use DBI;
use Getopt::Long;
use File::Basename;
use File::Spec;

## Startparams
GetOptions( "chanid=i"          => \$chanId,
            "starttime=s"       => \$startTime,
            "directory=s"       => \$fileDir,
            "file=s"            => \$fileName,
            "quality:i"         => \$quality,
            "verbose"           => \$verbose
    );

####################################################################################################
##############################################  Config  ############################################
####################################################################################################

## mythtv database connection
my $mythHost            = "localhost";
my $mythDb              = "mythconverg";
my $mythUser            = "mythtv";
my $mythPass            = "mythtv";

## owner of file after successful run
## works only if mythtv user has sufficient permissions to do this
## set a valid value /bin/chown would accept, eg. "reznor:users"
## setting ownership after encoding will be skipped if this variable is empty
my $fileOwner           = "";

## directory to store temp files in
## if it does not exist it will be created
my $tempDir             = "/tmp/nuvexport";

## target directory to store encoded files in
my $targetDir           = "/data/movies/x264";

## Video

## Video constant quality encoding option
## Check handbrake manual for valid values
my $videoQualityDefault = 20;

## Audio

## preferred audio language
## comma separated list
## check the list at
## http://www.loc.gov/standards/iso639-2/php/code_list.php
## for the correct iso639-2 codes
my $prefLang            = 'deu,eng';

## audio languages you wish to skip
## comma separated list
## mis = miscellaneous language
my $skipLang            = 'mis';

## The following filetypes are mapped to integer values
## The number value serves as priority
## If you have a recording with:
## - ac3 (stereo) and mp2 (stereo), mp2 with its higher priority will be selected
## - ac3 (5.1) and mp2 (stereo), ac3 will be selected, because it has more channels
## If you would like to change these priorities, you will have to change the corresponding
## key values of below mappings in $audioCodecMap and $audioBitrateMap, too.
##
## 0 => any other filetypes
## 1 => ac3
## 2 => mp2

## Preferred way of handbrake treating audio tracks by codec.
## The number value (key) corresponds to the codec mapping above (ac3, mp2, ..)
## The string value (value) represents the corresponding way how
## handbrake shall treat them.
## Since I don't know what I would choose if I had HD-tuners,
## I don't assume any values ... this is up to you :)
our $audioCodecMap = {  0 => 'lame', # unknown filetypes are going to be converted to mp3
                        1 => 'copy', # ac3 streams will be copied as they are (passthrough)
                        2 => 'lame'  # mp2 streams will be converted to mp3
};

## Preferred way of handbrake treating bitrates of audio tracks by codec.
## The number value (key) corresponds to the codec mapping above (ac3, mp2, ..)
## The number value (value) represents the corresponding bitrate selected for this codec.
## Usually (here in germany) ac3 6ch has a ~ bitrate of 448 kbit/s,
## mp2 has a ~ bitrate of 256, so I choose this values to get very good results.

our $audioBitrateMap = { 0 => 256,
                         1 => 448,
                         2 => 256
};

## Encoding priority
my $niceValue           = 19;

## Maximum allowed parallel executions of this script
my $maxExec             = 1;

## If $maxExec would exceed the allowed value, the amount of seconds to wait
## for other encoding processes to finish which were started by this script
my $sleepInterval       = 240;

## Maximum allowed time to sleep in seconds before aborting when waiting for other
## encodings started by this script
## If set to 0, it will wait forever
my $maxSleepTime        = 3600;

####################################################################################################
##############################################  Start  #############################################
####################################################################################################

## Logfile
our $logFile = $tempDir . "/" . $chanId . "_" . $startTime . ".log";

## If called interactively, log to STDOUT and logfile
our $hasTty  = -t STDIN && -t STDOUT;

## Switch off output buffering
$| = 1;

## Open logfile
open (LOG, ">> $logFile");

## Echo start of script
toLog("Start encoding $fileName", "INFO");

## What is my name?
my $scriptName = basename($0);

## Check command line options
checkOptions($chanId, $startTime, $fileDir, $fileName, $quality, $verbose, $scriptName, $videoQualityDefault);

## Directory where all the work is donw
my $workDir = $tempDir . "/" . $chanId . "_" . $startTime;

## Return code
my $rc = 0;

## Output of command line tools
my $output;

## Required programs for this script
my $requiredPrograms = { "mythtranscode" => "media-video/mythtv",
                         "HandBrakeCLI"  => "media-video/handbrake",
                         "mkvmerge"      => "media-video/mkvtoolnix"
};

## Check for required programs and replace package names by absolute path to program
toLog("Checking requirements", "INFO");
requirements($requiredPrograms);

## Check if maximum value of simultaneous encodings will exceed
toLog("Check if other instances are running", "INFO");
checkRunning($scriptName, $workDir, $maxExec, $sleepInterval, $maxSleepTime);

## Gather information about recording's title, subtitle, season and episode data
toLog("Gather information about recording's title, subtitle, season and episode", "INFO");
$recordingInfo = getRecordingInfo($mythHost, $mythDb, $mythUser, $mythPass, $fileDir, $fileName);

## Create working directory
toLog("Creating working directory '" . $workDir . "'", "INFO");
if (! -d $workDir)
{
    system("mkdir -p $workDir");
    die(toLog("Could not create " . $workDir . " : " . $!, "FATAL")) if ($? != 0);
}

## Start mythtranscode to cut out commercials and save the file lossless
toLog("Starting mythtranscode", "INFO");
toLog("Executing: nice -n $niceValue $$requiredPrograms{'mythtranscode'} --chanid $chanId --starttime $startTime --honorcutlist --mpeg2 --passthrough --outfile $workDir/$fileName 2>&1", "INFO") if ($verbose);

$output = `$$requiredPrograms{'mythtranscode'} --chanid $chanId --starttime $startTime --honorcutlist --mpeg2 --passthrough --outfile $workDir/$fileName 2>&1`;
print LOG $output if ($verbose);
die(toLog("mythtranscode exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.", "ERROR")) if ($? != 0);

toLog("mythtranscode finished", "INFO");

## Gather info about recording's audio tracks
toLog("Gather information about recording's audio tracks", "INFO");
$audioInfo = getAudioInfo($output);

## Get channel numbers, codecs and bitrates to use with handbrake
my (@channelLanguages, @channelNumbers, @channelCodecs, @channelBitrates);

foreach $lang (keys %$audioInfo)
{
    foreach $chan (keys %{$$audioInfo{$lang}})
    {
	foreach $fileT (keys %{$$audioInfo{$lang}{$chan}})
	{
	    push(@channelLanguages, $lang);
	    push(@channelNumbers, ($$audioInfo{$lang}{$chan}{$fileT} + 1));
	    push(@channelCodecs, $$audioCodecMap{$fileT});
	    push(@channelBitrates, $$audioBitrateMap{$fileT});
	    toLog("Selecting audio track " . ( $$audioInfo{$lang}{$chan}{$fileT} + 1) . ": Language: " . $lang . ", Channels: " . $chan . " Bitrate: " . $$audioBitrateMap{$fileT} . " kbit/s", "INFO");
	}
    }
}

my $audioLanguages      = join (',', @channelLanguages);
my $audioTracks         = join (',', @channelNumbers);
my $audioCodecs         = join (',', @channelCodecs);
my $audioBitrates       = join (',', @channelBitrates);

my $videoQuality = ($quality) ? $quality : $videoQualityDefault;

## Now that we have all information we need, let's get to encode it with handbrake
toLog("Starting handbrake", "INFO");
toLog("Executing: nice -n $niceValue $$requiredPrograms{'HandBrakeCLI'} -i $workDir/$fileName -o $workDir/$fileName.mkv -a $audioTracks -E $audioCodecs -B $audioBitrates -A $audioLanguages -f mkv -e x264 -q $videoQuality -x ref=2:bframes=2:subme=6:mixed-refs=0:weightb=0:8x8dct=0:trellis=0 -2 -T -d slower -s scan -F -N $prefLang --native-dub 2>&1", "INFO") if ($verbose);

$output = `nice -n $niceValue $$requiredPrograms{'HandBrakeCLI'} -i $workDir/$fileName -o $workDir/$fileName.mkv -a $audioTracks -E $audioCodecs -B $audioBitrates -A $audioLanguages -f mkv -e x264 -q $videoQuality -x ref=2:bframes=2:subme=6:mixed-refs=0:weightb=0:8x8dct=0:trellis=0 -2 -T -d slower -s scan -F -N $prefLang --native-dub 2>&1`;

print LOG $output if ($verbose);
die(toLog("handbrake exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.", "ERROR")) if ($? != 0);

toLog("handbrake finished", "INFO");

## Create a clean filename
my $title = $$recordingInfo{'title'};
$title =~ s#[<>\*\?\|:\"\\/]##g;

my $subtitle = $$recordingInfo{'subtitle'};
$subtitle =~ s#[<>\*\?\|:\"\\/]##g;
$metaSubtitle = $subtitle;
$subtitle = ($title =~ m/^$metaSubtitle$/ || $subtitle eq '') ? '' : ' - ' . $subtitle;

my $episode;
$episode = ($$recordingInfo{'season'} != 0 && $$recordingInfo{'season'} ne ''
	    && $$recordingInfo{'episode'} != 0 && $$recordingInfo{'episode'} ne '') ?
    sprintf(" - S%02dE%02d", $$recordingInfo{'season'}, $$recordingInfo{'episode'}) : '';

my $completeTitle       = $title . $episode . $subtitle;
my $metaTitle           = ($subtitle ne '') ? $metaSubtitle : $title;

## Create audio language names by muxed audio tracks
## Audio TrackId will start at 2 (1 is video track)
my $mkvmergeAudio;
my $mkvmergeAudioTrackId = 2;
foreach (@channelLanguages)
{
    $mkvmergeAudio .= " --language " . $mkvmergeAudioTrackId . ":" . $_;
    $mkvmergeAudioTrackId++;
}

## Check if target file already exists
## If so, append a timestamp to the target filename
if (-e $targetDir . "/" . $completeTitle . ".mkv")
{
    ($sec, $min, $hour, $day, $month, $year) = (localtime)[0,1,2,3,4,5];
    my $timeStamp = sprintf("%04d%02d%02d%02d%02d%02d", $year+1900, $month+1, $day, $hour, $min, $sec);
    $completeTitle = $completeTitle . "_" . $timeStamp;
}

## Put all information we gathered into the .mkv file/name
## And let mkvmerge write the finished file to the target directory
toLog("Starting mkvmerge", "INFO");
toLog("Executing: nice -n $niceValue $$requiredPrograms{'mkvmerge'} -o $targetDir/'$completeTitle.mkv' --title $metaTitle $mkvmergeAudio --default-track 2:yes $workDir/$fileName.mkv 2>&1", "INFO") if ($verbose);

$output = `nice -n $niceValue $$requiredPrograms{'mkvmerge'} -o $targetDir/"$completeTitle.mkv" --title "$metaTitle" $mkvmergeAudio --default-track 2:yes $workDir/$fileName.mkv 2>&1`;
print LOG $output if ($verbose);
die(toLog("mkvmerge exited with errors, run " . $scriptName . " --verbose and check logfile " . $logFile . " for errors.", "ERROR")) if ($? != 0);
toLog("mkvmerge finished", "INFO");

toLog("Cleaning up temporary files", "INFO");
cleanup($workDir, $fileOwner, $targetDir . "/" . $completeTitle . ".mkv");

toLog("Finished encoding to file '$completeTitle.mkv' ($fileName)", "INFO");
close(LOG);

exit 0;

####################################################################################################
##############################################  Functions ##########################################
####################################################################################################

sub toLog
{
    my ($message, $type) = @_;

    ($sec, $min, $hour, $day, $month, $year) = (localtime)[0,1,2,3,4,5];
    my $timeStamp = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year+1900, $month+1, $day, $hour, $min, $sec);

    $formattedMessage = sprintf("%s %-5s %s\n", $timeStamp, $type, $message);

    print $formattedMessage if ($hasTty);

    print LOG $formattedMessage;
}

sub requirements
{
    my $requiredPrograms = $_[0];
    my $wrc = 0;

    foreach $program (keys %$requiredPrograms)
    {
	$absolutePath = `which $program`;
	chomp($absolutePath);

	if ($? != 0)
	{
	    toLog("Required program " . $program . " (" . $$requiredPrograms{$program} . ") not found.", "FATAL");
	    $wrc = 1;
	} else {
	    @$requiredPrograms{$program} = $absolutePath;
	}
    }
}

sub checkRunning
{
    my ($scriptName, $workDir, $maxExec, $sleepInterval, $maxSleepTime) = @_;
    my @pids = ();
    my $slept = 0;

    my $curProcs = `ps aux | grep $scriptName | grep -v grep | wc -l`;
    chomp($curProcs);

    ## Check if encoding of this recording has already been started.
    ## If so, abort.
    if (-d $workDir)
    {
	die(toLog("Encoding of this recording already running in directory " . $workDir . ". Or an error occurred in previous attempt to encode this recording. Aborting.", "WARN"));
    }

    while ($curProcs > $maxExec)
    {
	$curProcs = `ps aux | grep $scriptName | grep -v grep | wc -l`;
	chomp($curProcs);

	toLog($scriptName . " maximum amount of simultaneous executions reached. Waiting " . $sleepInterval . " seconds before trying again.", "INFO");
	sleep($sleepInterval);
	$slept += $sleepInterval;

	if ($maxSleepTime > 0 && $slept > $maxSleepTime)
	{
	    toLog("Maximum waiting time of " . $maxSleepTime . " seconds exceeded.", "FATAL");
	    die(toLog("Something might be wrong, please check unfinished encoding jobs. Aborting.", "FATAL"));
	}
    }
}

sub in_array
{
    my ($item, $array) = @_;
    my %hash = map { $_ => 1 } @$array;
    if ($hash{$item}) { return 1; } else { return 0; }
}

sub getRecordingInfo
{
    my ($mythHost, $mythDb, $mythUser, $mythPass, $fileDir, $fileName) = @_;

    ## Establish DB connection
    $dbh = DBI->connect("DBI:mysql:$mythDb:$mythHost", $mythUser, $mythPass);

    ## Fetch recorded info
    $sql = "SELECT title, subtitle, season, episode FROM " . $mythDb . ".recorded WHERE basename='" . $fileName . "';";

    $sqlQuery  = $dbh->prepare($sql)
        or die(toLog("Can't prepare $sql: $dbh->errstr\n", 'FATAL'));
    $sqlQuery->execute
        or die(toLog("can't execute the query: $sqlQuery->errstr\n", 'FATAL'));

    my $recordingInfo = $sqlQuery->fetchrow_hashref;
    my $rows                = $sqlQuery->rows;

    $rc = $sqlQuery->finish;

    if (! $rc || $rows == 0)
    {
	die(toLog("RC: $rc No recording Info for $fileDir/$fileName found!", 'FATAL'));
    }

    toLog("Title: '" . $$recordingInfo{'title'} . "', Subtitle: '" . $$recordingInfo{'subtitle'} . "', Season: '" . $$recordingInfo{'season'} . "', Episode: '" . $$recordingInfo{'episode'} . "'", "INFO");

    return $recordingInfo;
}

sub getAudioInfo
{
    ## Process audio streams
    foreach (split /\n/, $_[0])
    {
	push(@audioLines, $_) if $_ =~ m/Audio/;
    }

    ## Lines with word "Audio" appear twice (for input and output file) in mythtranscode's output
    ## so divide the amount of lines by 2 to have the correct stream count ;)
    ## By the way we catch all info of the audio streams given by mythtranscode
    ## Boil down to the really needed audio streams in the encoded file
    ##
    ## Prefer 2 channel mp2 over 2 channel ac3.
    ## Prefer 6 channel audio over 2 channel audio.
    ## Prefer 8 channel audio over 6 channel audio.
    ## Keep different languages as well by still following rules above.

    my %audioInfo;
    my @skipLanguages = split /,/, $skipLang;

    for ($i = 0; $i < (@audioLines / 2); $i++)
    {
	my $language    = $audioLines[$i];
	$language               =~ s/^[^\(]+\(([^\)]+)\):.*/$1/;

	# Skip over to next audio track if this language shall be skipped
	next if (in_array($language, \@skipLanguages));

	my $fileType    = $audioLines[$i];
	$fileType               =~ s/^.*Audio: ([^,]),.*/$1/;
	$fileType               = ($fileType !~ m/ac3|mp2/) ? 0 : $fileType; # any other filetype I don't know has priority 0 :)
	$fileType               = ($fileType =~ m/ac3/)         ? 1 : $fileType; # ac3 priority 1
	$fileType               = ($fileType =~ m/mp2/)         ? 2 : $fileType; # mp2 priority 2 (if equal amount of channels, prefer mp2)

	my $chan                = $audioLines[$i];
	my @chanArray   = split /,/, $chan;
	my $channels    = $chanArray[2];
	$channels               =~ s/^\s*|\s*$//g;

	$channels               = ($channels =~ m/2 channels|stereo/)   ? 2 : $channels;
	$channels               = ($channels =~ m/6 channels|5\.1/)             ? 6 : $channels;
	$channels               = ($channels =~ m/8 channels|7\.1/)             ? 8 : $channels;

	if (! exists $audioInfo{$language}{$channels}{$fileType})
	{
	    $audioInfo{$language}{$channels}{$fileType} = $i;
	}

	foreach $aIChannels (keys %{$audioInfo{$language}})
	{
	    if ($aIChannels == $channels)
	    {
		foreach $aIFileType (keys %{$audioInfo{$language}{$aIChannels}})
		{
		    if ($aIFileType < $fileType)
		    {
			delete $audioInfo{$language}{$channels};
			$audioInfo{$language}{$channels}{$fileType} = $i;
		    } elsif ($aIFileType > $fileType)
		    {
			delete $audioInfo{$language}{$channels}{$fileType};
		    }
		}
	    } elsif ($aIChannels < $channels)
	    {
		delete $audioInfo{$language};
		$audioInfo{$language}{$channels}{$fileType} = $i;
	    }
	}
    }

    return \%audioInfo;
}

sub cleanup
{
    my ($workDir, $fileOwner, $targetFile) = @_;

    ## Delete working directory
    if ($workDir ne '')
    {
        $output = `rm -r $workDir 2>&1`;

        if ($? != 0)
        {
            toLog("Failed to delete " . $workDir ." : " . $!, "ERROR");
        }
    } else
    {
        toLog("Not deleting empty \$workdir variable. There's something wrong.. :(", "ERROR");
    }

    ## Set ownership
    if ($fileOwner ne '')
    {
        my $execUser = `whoami`;
        chomp($execUser);

        if ($execUser !~ m/root/)
        {
            $chownCommand = `which chown`;
            chomp($chownCommand);

            $output = `sudo -ln $chownCommand $fileOwner "$targetFile" >/dev/null 2>&1`;

            if ($? == 0)
            {
                $output = `sudo $chownCommand $fileOwner "$targetFile" 2>&1`;

                if ($? != 0)
                {
                    toLog("Failed to set preferred file owner: " . $!, "ERROR");
                }
            } else
            {
                toLog("Failed to set preferred file owner '$fileOwner'.", "ERROR");
                toLog("The user '$execUser' executing this script is neither root nor the use of \"sudo $chownCommand $fileOwner '$targetFile'\" is allowd by sudoers.", "ERROR");
            }
        } else
        {
            toLog("Setting preferred file owner '$fileOwner' to encoded file", "INFO");
            $output = `chown $fileOwner "$targetFile" 2>&1`;

            if ($? != 0)
            {
                toLog("Failed to set preferred file owner: " . $!, "ERROR");
            }
        }
    }
}

sub checkOptions
{
    my ($chanId, $startTime, $fileDir, $fileName, $quality, $verbose, $scriptName, $videoQualityDefault) = @_;
    my $failedChecks = 0;

    if ($chanId eq '' || $chanId =~ /\D/)
    {
        toLog("chanid not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($startTime eq '' || $startTime =~ /\D/)
    {
        toLog("starttime not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($fileDir eq '')
    {
        toLog("directory not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($fileName eq '')
    {
        toLog("filename not set or invalid", "FATAL");
        $failedChecks++;
    }

    if ($quality =~ /\D/ || $quality < 0 || $quality > 51)
    {
        toLog("constant quality value invalid", "FATAL");
        $failedChecks++;
    }

    if ($failedChecks > 0)
    {
        usage($scriptName, $videoQualityDefault);
        exit 1;
    }
}

sub usage
{
    my ($scriptName, $videoQualityDefault) = @_;

    $usage = <<EOL;

Usage:  $scriptName --chanid=[int value] --starttime=[int value] --directory=[string value] --file=[string value] --quality=[int value] --verbose

    --chanid                MythTV CHANID [REQUIRED]
    --starttime             MythTV STARTTIME [REQUIRED]
    --directory             MythTV storage directory [REQUIRED]
    --file                  MythTV filename of recording [REQUIRED]
    --quality               Constant Quality factor [51..0] used by handbrake
    Look up 'https://trac.handbrake.fr/wiki/ConstantQuality'
    for more information
    [OPTIONAL] defaults to $videoQualityDefault
    --verbose               Write output of mythtranscode, handbrake and mkvmerge to logfile
    [OPTIONAL] toggle

    For installation as mythtv user job, it may be called like this:
    ../myth_make_x264.pl --chanid=%CHANID% --starttime=%STARTTIME% --directory=%DIR% --file=%FILE%

EOL

        toLog($usage, "USAGE");
}
