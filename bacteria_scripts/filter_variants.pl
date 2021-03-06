#!/usr/bin/perl -w

# Applies the same filters as map_snp_call to a vcf

use strict;
use warnings;

use Getopt::Long;
use File::Spec;

# Allows use of perl modules in ./
use Cwd 'abs_path';
use File::Basename;
use lib dirname( abs_path $0 ) . "/../assembly_scripts";
use lib dirname( abs_path $0 );

use mapping;

# VCF filters
my @vcf_filters = ("FORMAT/DP < 4", "IDV < 4 || IMF < 0.2", "AF1 > 0.2 && AF1 < 0.8", "QUAL < 50", "MQ < 26", "PV4[*] < 0.001", "MQSB < 0.001", "RPB < 0.001", );
my @vcf_filter_names = ("DEPTH", "INDEL_DEPTH", "HET", "VAR_QUAL", "MAP_QUAL", "PV4_BIAS", "MQ_BIAS", "RP_BIAS");

my $usage_message = <<USAGE;
Usage: ./filter_variants.pl -v <vcf_file> -o <output>

Applies basic filters to variants in a VCF. Modifies the FILTER field in the VCF provided
USAGE

#* gets input parameters
my ($input_vcf, $output_vcf, $help);
GetOptions("vcf|v=s"  => \$input_vcf,
           "out|o=s" =>\$output_vcf,
            "help|h"     => \$help
          ) or die($usage_message);

if (defined($help) || !-e $input_vcf)
{
   print $usage_message;
}
else
{
   # Filter variants
   mapping::filter_vcf($input_vcf, $output_vcf, \@vcf_filters, \@vcf_filter_names);
}

exit(0);

