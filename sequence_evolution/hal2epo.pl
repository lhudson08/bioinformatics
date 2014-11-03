#!/usr/bin/perl -w
#
# Extracts the mutations on a given branch of a hal file (possibly generated by
# progressiveCactus) and formats them as a .log file as extracted from the
# ensembl EPO pipeline
#
use strict;
use warnings;

use Getopt::Long;

use Bio::SeqIO;

#
# Globals
#
my $haltools_location = "~/pathogen_nfs/large_installations/progressiveCactus/submodules/hal/bin/";

my $tmp_bed_prefix = join('', (map +(0..9,'a'..'z','A'..'Z')[rand(10+26*2)], 1..8)) . "tmp_bed";

my @snp_headers = ("AC", "AG", "AT", "CA", "CG", "CT", "GA", "GC", "GT", "TA", "TC", "TG");
my @CpG_headers = ("CA", "CG", "CT", "GA", "GC", "GT");

my $help_message = <<HELP;
Usage: ./hal2epo.pl -f <reference_fasta> -h <hal_file> -n <ref_name> > output.log

Takes the mutations along a branch from anc0 to the given ref_name in a hal file, and converts
them to an epo like format for use with mutate_bacteria.py
Options:
   -f --fasta     The reference used in the alignment, in fasta format
   -h --hal       The hal file the alignment is stored in
   -n --name      The name of the branch tip in the hal file to summarise

   --interpolate  Linearly interpolate any missing indel lengths between the min and max
                  observed

   --dirty        Do not clear up bed files produced by hal

   --help         This help message

Prints log summary file to stdout and logs to stderr
HELP

#
# Subs
#
sub interpolate($$$$$)
{
   my ($x_int, $x1, $y1, $x2, $y2) = @_;

   my $gradient = ($y2 - $y1)/($x2 - $x1);

   my $y_int = sprintf("%0.f", $y1 + ($x_int-$x1) * $gradient);

   return ($y_int);
}

#
# Main
#

# Read in options
# Reference fasta, hal file, reference name in hal
my ($fasta_file, $hal_file, $ref_name, $interpolate, $dirty, $help);
GetOptions ("fasta|f=s"  => \$fasta_file,
            "hal|h=s" => \$hal_file,
            "name|n=s"  => \$ref_name,
            "interpolate" => \$interpolate,
            "dirty" => \$dirty,
            "help"     => \$help
		   ) or die($help_message);

if (defined($help))
{
   print STDERR $help_message;
}
elsif (!defined($fasta_file) || !defined($hal_file) || !defined($ref_name))
{
   print STDERR "The options -f, -h and -n are mandatory\n";
   print STDERR $help_message;
}
else
{
   # Run hal tools command
   my $hal_command = "$haltools_location/halBranchMutations --refFile $tmp_bed_prefix.SV.bed --snpFile $tmp_bed_prefix.snps.bed $hal_file $ref_name";
   system($hal_command);

   # Count number of each possible mutation from hal output bed
   my (%snp_counts, %snp_types);
   my @CG_snps;
   open(SNPS, "$tmp_bed_prefix.snps.bed") || die("Could not open $tmp_bed_prefix.snps");

   while (my $snp_line = <SNPS>)
   {
      if($snp_line !~ /^#/)
      {
         chomp($snp_line);

         # End is the position of the snp
         my ($sequence, $start, $end, $mut_id, $par_genome, $child_genome) = split("\t", $snp_line);

         $mut_id =~ m/^S_([AGCT][AGCT])$/;
         my $substitution = $1;

         # Add any non CpG muts to a count
         if ($substitution =~ /^[AT]/)
         {
            $snp_counts{"norm"}{$substitution}++;
         }
         # Count possible CpG sites later when looking through fasta
         else
         {
            push(@CG_snps, $end);
            $snp_types{$end} = $substitution;
         }
      }
   }

   close SNPS;

   # Go through fasta and count numbers of each base. Also check any CpG sites to
   # see if there was a mutation in them

   # Open fasta
   my $fasta_ref = Bio::SeqIO->new(-file => $fasta_file, -format => 'fasta') || die("Failed to open $fasta_file: $!\n");

   my %base_count;
   my $length = 0;
   while (my $sequence = $fasta_ref->next_seq())
   {
      my $seq_string = $sequence->seq();
      $length += length($seq_string);

      # Go through each base
      my @sequence_array = split(//, $seq_string);

      my $next_CG_snp = shift(@CG_snps);
      for (my $i = 0; $i<scalar(@sequence_array); $i++)
      {
         # Base counts
         my $base = $sequence_array[$i];
         $base_count{$base}++;

         # CpG counts
         if ($base eq "C" && $sequence_array[$i+1] eq "G")
         {
            $base_count{"CpG"}++;
         }

         # Check type of C/G SNPs i.e. if they are in a CpG site
         if ($i == $next_CG_snp-1)
         {
            if (($snp_types{$i+1} =~ /^C/ && $sequence_array[$i+1] eq "G") || ($snp_types{$i+1} =~ /^G/ && $sequence_array[$i-1] eq "C"))
            {
               $snp_counts{"CpG"}{$snp_types{$i+1}}++;
            }
            else
            {
               $snp_counts{"norm"}{$snp_types{$i+1}}++;
            }

            if (scalar(@CG_snps))
            {
               $next_CG_snp = shift(@CG_snps);
            }
            else
            {
               $next_CG_snp = 0;
            }
         }
      }
   }

   $fasta_ref->close();

   # Count number and length of each indel from hal output bed
   # Interpolate any missing length frequencies
   open(SV, "$tmp_bed_prefix.SV.bed") || die("Could not open $tmp_bed_prefix.SV");

   my %SV;
   while (my $sv_line = <SV>)
   {
      if($sv_line !~ /^#/)
      {
         chomp($sv_line);

         # End is the position of the snp
         my ($sequence, $start, $end, $mut_id, $par_genome, $child_genome) = split("\t", $sv_line);

         my $SV_length = $end - $start;
         if ($mut_id eq "I")
         {
            $SV{"insertions"}{$SV_length}++;
         }
         elsif ($mut_id eq "GI")
         {
            $SV{"deletions"}{$SV_length}++;
         }

      }
   }

   close SV;

   # Linear interpolation of indels
   if (defined($interpolate))
   {
      foreach my $sv_type (keys %SV)
      {
         my $i = 1;
         my $last_length = 0;
         foreach my $sv_length (sort {$a <=> $b} keys %{ $SV{$sv_type}})
         {
            while ($i < $sv_length)
            {
               if ($last_length != 0)
               {
                  $SV{$sv_type}{$i} = interpolate($i, $last_length, $SV{$sv_type}{$last_length}, $sv_length, $SV{$sv_type}{$sv_length});
               }
               else
               {
                  $SV{$sv_type}{$i} = interpolate($i, 1, 0, $sv_length, $SV{$sv_type}{$sv_length});
               }

               $i++;
            }
            $last_length = $sv_length;
         }
      }
   }
   # Get number of aligned sites
   my $hal_snp_command = "$haltools_location/halSnps $hal_file $ref_name Anc0";
   my @orthologous_sites = split(" ", `$hal_snp_command`);

   # An estimate of CpG aligned sites
   # TODO: is there a better way of getting this from the hal?
   my $aligned_cpg = sprintf("%.0f", $base_count{CpG} * ($orthologous_sites[2]/$length));
   my $CpG_snps;
   foreach my $CpG_header (@CpG_headers)
   {
      $CpG_snps += $snp_counts{CpG}{$CpG_header};
   }

   # Print output in a format similar to .log
   print "##STATS\n";

   # Base counts
   print join("\t", "#A", "C", "G", "T", "CpG\n");
   print join("\t", $base_count{A}, $base_count{C}, $base_count{G}, $base_count{T}, $base_count{CpG}) . "\n";

   # SNP counts
   print join("\t", "#y", "N");
   foreach my $snp_header (@snp_headers)
   {
      print "\t$snp_header";
   }
   print "\n";

   print join("\t", $orthologous_sites[1], $orthologous_sites[2]);
   foreach my $snp_header (@snp_headers)
   {
      print "\t$snp_counts{norm}{$snp_header}";
   }
   print "\n";

   # CpG SNP counts
   print join("\t", "#yCpG", "NCpG");
   foreach my $CpG_header (@CpG_headers)
   {
      print "\t$CpG_header";
   }
   print "\n";

   print join("\t", $aligned_cpg, $CpG_snps);
   foreach my $CpG_header (@CpG_headers)
   {
      print "\t$snp_counts{CpG}{$CpG_header}";
   }
   print "\n";

   # Now print insertions, using interpolation of any missing lengths up to the max
   # observed length
   foreach my $sv_type (reverse sort keys %SV)
   {
      print "##$sv_type\n";
      print "#len\tcount\n";

      foreach my $sv_length (sort {$a <=> $b} keys %{ $SV{$sv_type}})
      {
         print join("\t", $sv_length, $SV{$sv_type}{$sv_length} . "\n");
      }
   }

   # Clean up
   unless ($dirty)
   {
      unlink "$tmp_bed_prefix.SV.bed", "$tmp_bed_prefix.snps.bed";
   }
}

exit(0);

