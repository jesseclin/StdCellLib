#!/usr/bin/perl -w

mkdir "outputlib";
mkdir "debuglib";

my $debug=1;

my $sp=$ARGV[0]||"libresilicon.sp";

$ENV{'PySpiceLogLevel'}="DEBUG" if($debug);
$ENV{'PySpiceLogLevel'}="ERROR" if(!$debug);
#undef($ENV{'PySpiceLogLevel'}) unless($debug);

my $lctimeparams="--output-loads 0.0005,0.05,0.1,0.2,1 --slew-times 0.01,0.05,0.1,0.2,1.5 --related-pin-transition 0.01,0.05,0.1,0.2,1.5";
if(open IN,"<../Tech/lctime.conf")
{
  $lctimeparams=<IN>; $lctimeparams=~tr/\r\n//;
  close IN;
}

sub system_v($)
{
  print "$_[0]\n";
  #print STDERR "$_[0]\n";
  return system($_[0]);
}


system_v "../Tools/perl/cell2spice.pl";

mkdir "work";
system "rm -rf work/*";

open IN,"<$sp" || die "Could not open file $sp: $!\n";
while(<IN>)
{
  if(m/^\.subckt (\w+)/)
  {
    our $cellname=$1;
    next if(defined($ENV{'CELL'}) && $cellname ne $ENV{'CELL'});
    if(-s "$cellname.lib" && (-s "$cellname.mag")>55)
    {
      print STDERR "INFO: $cellname.lib already exists, so we are skipping it.\n";
      next;
    }
    unlink "$cellname.done";
    unlink "$cellname.log";
    unlink "$cellname.err";
    open OUT,">$cellname.running";
    close OUT;

    my $usage="/usr/bin/time -v -a -o $cellname.usage";

    sub step($)
    {
      print "$_[0]\n";
      open LOG,">>$cellname.log";
      print LOG $_[0]."\n";
      close LOG;
      open LOG,">>$cellname.err";
      print LOG $_[0]."\n";
      close LOG;
    }

    step("NEXT CELL: $cellname");

    system_v "../Tools/perl/truthtable.pl --format=text $cellname.cell >$cellname.truthtable.txt";
    system_v "../Tools/perl/truthtable.pl --format=html $cellname.cell >$cellname.truthtable.html";
    system_v "../Tools/perl/truthtable.pl --format=verilog $cellname.cell >$cellname.truthtable.v";


    my $placer=""; $placer="--placer hierarchical" if($cellname=~m/^(CLK|DFF|FAX|HAX)/);
    if(-f "$cellname.dontlayout")
    {
      print STDERR "TODO: $cellname is disabled by $cellname.dontlayout this is likely because it takes too much time to generate it\n";
      unlink "$cellname.running";
      next;
    }
    unlink "outputlib/$cellname.mag";
    step("NEXT STEP: Running cell2spice");
    system_v "../Tools/perl/cell2spice.pl $cellname >>$cellname.log 2>>$cellname.err";
    step("NEXT STEP: Running lclayout");

    system_v "$usage lclayout --output-dir outputlib --tech ../Tech/librecell_tech.py --netlist $cellname.sp --cell $cellname -v $placer --placement-file $cellname.place --ignore-lvs --debug-routing-graph --route-max-iter 100 >>$cellname.log 2>>$cellname.err";


    if(-f "$cellname.mag")
    {
      system_v("../Tools/perl/paintgridusage.pl $cellname >>$cellname.log 2>>$cellname.err");
    }

    my $magfile="outputlib/$cellname.mag";
    my $gdsfile="outputlib/$cellname.gds";
    if(-f "$cellname.fixed")
    {
      print "We found a manually fixed $cellname.fixed magic file for testing so we are using that one instead.\n";
      step("NEXT STEP: Fixing file $cellname.fixed -> $cellname.mag");
      system "cp -f $cellname.fixed $cellname.mag";
    }
    elsif(-f $magfile && (-s $magfile) > 51) # Has lclayout exported magic directly?
    {
      # Then we dont have to convert it
      open MAGIN,"<outputlib/$cellname.mag";
      open MAGOUT,">$cellname.mag";
      my $old=$/;
      undef $/;
      my $magcontent=<MAGIN>;
      $/=$old;
      #$magcontent=~s/tech sky130A/tech sky130A\nmagscale 1 2/s;
      $magcontent=~s/magscale 1 1/magscale 1 2/s;
      $magcontent=~s/<< abutment >>\nrect /<< properties >>\nstring FIXED_BBOX /s;
      print MAGOUT $magcontent;
      close MAGIN;
      close MAGOUT;
    }
    elsif(-f $gdsfile)
    {
      print STDERR "lclayout has exported GDS2 but no magic, so we try to convert the GDS2:\n";
      # For this processing step, the refrenced libresilicon.tech file needs to contain the cifinput section to import from GDS and the extract section to do the parasitic extraction:
      open OUT,"|magic -dnull -noconsole -T ../Tech/libresilicon.tech >>$cellname.log 2>>$cellname.err";
      print OUT <<EOF
drc off
cellname rename (UNNAMED) $cellname
box 0 0 0 0
gds readonly true
gds rescale true
gds warning align
gds ordering yes
gds read outputlib/$cellname
select
port makeall
writeall force $cellname
quit -noprompt
EOF
; # $cellname.spice
      close OUT;
    }
    
    if(!-f $magfile)
    {
      print STDERR "Error: lclayout has not generated Magic or GDS2, or we could not convert GDS2 to magic.\n";
      unlink "$cellname.running";
      next;
    }

    unlink "$cellname.nodes";
    unlink "$cellname.res.ext";
    unlink "$cellname.spice";
    unlink "$cellname.ext";
    unlink "$cellname.al";
    unlink "$cellname.res.lump";
    unlink "$cellname.sim";
    unlink "$cellname.drclog";

    step("NEXT STEP: DRC Check with Magic");
    system "$usage ../Tools/perl/drccheck.pl $cellname.mag |tee $cellname.mag.drc";

    step("NEXT STEP: DRC Fix");
    system_v "$usage ../Tools/perl/drcfix.pl $cellname.mag ../Tech/libresilicon.tech >>$cellname.log 2>>$cellname.err";
    if(-f "corr_$cellname.mag")
    {
      unlink "$cellname.predrc.mag";
      rename "$cellname.mag","$cellname.predrc.mag";
      rename "corr_$cellname.mag","$cellname.mag";

      #step("NEXT STEP: DRC Fix - 2nd try, just to make sure");
      #system "../Tools/perl/drcfix.pl $cellname.mag >>$cellname.log 2>>$cellname.err";
      #if(-f "corr_$cellname.mag")
      #{
      #  unlink "$cellname.mag" ;
      #  rename "corr_$cellname.mag","$cellname.mag";
      #}

      step("NEXT STEP: Final DRC check");
      print "DRC errors in $cellname corrected. Now running final DRC check:\n";
      system_v "$usage ../Tools/perl/drccheck.pl $cellname.mag";
    }
    step("DRC Fixing done.");

    step("NEXT STEP: mag2gds");
    print "The outputlib/$cellname.gds is being overwritten by the GDS file converted by Magic from the .mag file, to propagate the DRC corrections to GDS.\n";
    rename "outputlib/$cellname.gds","outputlib/$cellname.lclayout.gds";
    unlink "$cellname.gds";
    open OUT,"|magic -dnull -noconsole -T ../Tech/libresilicon.tech $cellname.mag >>$cellname.log 2>>$cellname.err";
    print OUT <<EOF
gds
quit -noprompt
EOF
;
    close OUT;
    rename "$cellname.gds","outputlib/$cellname.gds";

    step("NEXT STEP: magic extraction");
    open OUT,"|$usage magic -dnull -noconsole -T ../Tech/libresilicon.tech $cellname.mag >>$cellname.log 2>>$cellname.err";
    print OUT <<EOF
extract warn all
extract all
ext2sim rthresh 0
ext2sim cthresh 0
ext2sim alias on
ext2sim labels on
ext2sim
#extresist tolerance 10
#extresist simplify off
#extresist extout on
#extresist lumped on
#extresist geometry
extresist all
quit -noprompt
EOF
;
    close OUT;
    #system "cat $cellname.res.ext >>$cellname.ext";
    #system "cat $cellname.ext";
    print "Second magic call:\n";
    step("NEXT STEP: magic3");
    open OUT,"|$usage magic -dnull -noconsole -T ../Tech/libresilicon.tech $cellname.mag >>$cellname.log 2>>$cellname.err";
    print OUT <<EOF
ext2sim rthresh 0
ext2sim cthresh 0
ext2sim alias on
ext2sim labels on
ext2sim
ext2spice cthresh 0
ext2spice rthresh 0
ext2spice format ngspice
ext2spice subcircuits on
ext2spice extresist off
ext2spice hierarchy on
ext2spice $cellname.spice
ext2spice
quit -noprompt
EOF
;
    close OUT;



    step("NEXT STEP: Generating Liberty Template");
    system_v "../Tools/perl/libgen.pl $cellname.mag >$cellname.libtemplate 2>>$cellname.err";

    step("NEXT STEP: Characterization with lctime:");
    $cmd="$usage lctime ".($debug?"--debug":"")." --diff %_p,%_n --liberty $cellname.libtemplate --include ../Tech/libresilicon.m --spice $cellname.spice --cell $cellname --output $cellname.lib $lctimeparams >>$cellname.log 2>>$cellname.err"; # This is for fully extracted parasitics
    #system_v($cmd);

    $cmd="$usage lctime ".($debug?"--debug":"")." --diff %_p,%_n --liberty $cellname.libtemplate --include ../Tech/libresilicon.m --spice $cellname.sp    --cell $cellname --output $cellname.lib $lctimeparams >>$cellname.log 2>>$cellname.err"; # This is for pure spice files without parasitics
    system_v($cmd);


    step("NEXT STEP: Characterization with CharLib:");
    # system_v("python3 ../Tools/python/gen_CharLib.py"); # Old CharLib and Libretto support
    system_v("perl ../Tools/perl/gencharlibyml.pl $cellname.cell");
    $cmd="$usage charlib run $cellname.yml >>$cellname.log 2>>$cellname.err"; # Which Path should we use for CharLib?
    system_v($cmd);

    step("NEXT STEP: Visualisation");
    print "Visualisation:\nlibertyviz -l $cellname.lib --cell $cellname --pin Y --related-pin A --table cell_rise\n";

    step("NEXT STEP: gds2mag");
    #system "gds2mag --config ~/libresilicon/gds2mag/example/example_config.toml -i outputlib/$1.gds -o _$1.mag";
    #    exit; # Stop after doing one cell

    step("NEXT STEP: mag2svg");
    system "../Tools/perl/mag2svg.pl $cellname.mag $cellname.svg" if(-f "$cellname.mag");
    step("NEXT STEP: mag2siliwiz");
    system "../Tools/perl/mag2siliwiz.pl <$cellname.mag >$cellname.json" if(-f "$cellname.mag");


    unlink "$cellname.running";
  }
}

if(!defined($ENV{'CELL'}))
{
  print "WRAPUP STEP: Concatenating GDS files\n";
  system_v "python3 ../Tools/python/concat4gds.py outputlib/*.gds";
}

