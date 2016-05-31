#!/usr/bin/env perl
# Name:           GenPro_read_seqant_db
#
# Description:    reads the seqant db to allow for verification that the database
#                 was created correctly
#
# Date Created:   Sat Aug 23 20:12:01 2014
# Date Modified:  Sat Aug 23 20:12:01 2014
# By:             TS Wingo

use autodie;
use Cwd;
use Cpanel::JSON::XS;
use Digest::MD5;
use Fcntl qw(:DEFAULT :seek);
use Getopt::Long;
use Modern::Perl '2013';

my @chrs = ( 1 .. 22 );
my ( $db_location, $db_name, $show_only_coding );
push @chrs, "X", "Y", "M";
foreach my $i ( 0 .. $#chrs ) {
  $chrs[$i] = "chr" . $chrs[$i];
}
#<<< No perltidy
my %codon_2_aa = (
  "AAA" => "K", "AAC" => "N", "AAG" => "K", "AAT" => "N",
  "ACA" => "T", "ACC" => "T", "ACG" => "T", "ACT" => "T",
  "AGA" => "R", "AGC" => "S", "AGG" => "R", "AGT" => "S",
  "ATA" => "I", "ATC" => "I", "ATG" => "M", "ATT" => "I",
  "CAA" => "Q", "CAC" => "H", "CAG" => "Q", "CAT" => "H",
  "CCA" => "P", "CCC" => "P", "CCG" => "P", "CCT" => "P",
  "CGA" => "R", "CGC" => "R", "CGG" => "R", "CGT" => "R",
  "CTA" => "L", "CTC" => "L", "CTG" => "L", "CTT" => "L",
  "GAA" => "E", "GAC" => "D", "GAG" => "E", "GAT" => "D",
  "GCA" => "A", "GCC" => "A", "GCG" => "A", "GCT" => "A",
  "GGA" => "G", "GGC" => "G", "GGG" => "G", "GGT" => "G",
  "GTA" => "V", "GTC" => "V", "GTG" => "V", "GTT" => "V",
  "TAA" => "*", "TAC" => "Y", "TAG" => "*", "TAT" => "Y",
  "TCA" => "S", "TCC" => "S", "TCG" => "S", "TCT" => "S",
  "TGA" => "*", "TGC" => "C", "TGG" => "W", "TGT" => "C",
  "TTA" => "L", "TTC" => "F", "TTG" => "L", "TTT" => "F"
);
#<<<
my %hCoding_status = ( "0" => "Coding", "1" => "Intergenic", "2" => "Intronic" );

die "Usage: $0
    --l|ocation <seqant db location>
    --n|ame <name of seqant db, e.g., hg19, hg18, mm10, etc.>
    [--c|coding] : only print coding bases\n"
  unless GetOptions(
  'l|location=s' => \$db_location,
  'n|db_name=s'  => \$db_name,
  'c|coding'     => \$show_only_coding,
  )

  and $db_location,
  and $db_name;

foreach my $chr (@chrs) {
  open( my $fpIDX, "<", "$db_location/$db_name.$chr.idx" );
  binmode $fpIDX;
  my $idx_typedef      = "L S L S C";
  my $idx_typedef_size = length( pack($idx_typedef) );

  open( my $fpSNP, "<", "$db_location/$db_name.$chr.snp" );
  binmode $fpSNP;
  my $snp_typedef      = "L C C";
  my $snp_typedef_size = length( pack($snp_typedef) );

  open( my $fpDAT, "<", "$db_location/$db_name.$chr.bgd" );
  binmode $fpDAT;
  my $dat_typedef      = "I C C S C Z25 h40";
  my $dat_typedef_size = length( pack($dat_typedef) );

  open( my $fpGID, "<", "$db_location/$db_name.$chr.gid" );
  binmode $fpGID;
  my $gid_typedef      = "Z16";
  my $gid_typedef_size = length( pack($gid_typedef) );

  my $json = Cpanel::JSON::XS->new();
  my $pos  = 0;

  while ( read( $fpIDX, my $idx_buffer, $idx_typedef_size ) ) {
    my %records;
    my ( @snp_results, @gene_results, $gene_name );
    my (
      $dat_file_offset, $dat_record_len, $snp_file_offset,
      $snp_record_len,  $coding_status
    ) = unpack( $idx_typedef, $idx_buffer );
    my $tmp = sprintf(
      "dat_offset: %x, dat_len: %x, snp_offset: %x, snp_len: %x, coding_status: %x",
      $dat_file_offset, $dat_record_len, $snp_file_offset,
      $snp_record_len,  $coding_status
    );

    next if $coding_status != 0 and $show_only_coding;
    say "$chr:$pos $hCoding_status{$coding_status} => $tmp";

    #
    # read dat file
    #
    if ( $dat_record_len > 0 ) {
      my $dat_buffer;
      seek( $fpDAT, $dat_file_offset, SEEK_SET );
      while ( $dat_record_len > 0 ) {
        read( $fpDAT, $dat_buffer, $dat_typedef_size ) == $dat_typedef_size
          || die
          "error reading $db_location/$db_name.$chr.bgd at address $dat_file_offset\n";
        my @tmp = unpack( $dat_typedef, $dat_buffer );

        # @tmp format:
        #      [0] Gene Number
        #      [1] Coding/UTR & Orientation
        #      [2] Codon
        #      [3] Amino Acid Number
        #      [4] Error Code
        #      [5] RefSeq Id
        #      [6] sha1_hex digest of gene_entry b/c refseq names are not unique

        #
        # gene name
        #
        my $gid_file_offset = ( $tmp[0] - 1 ) * $gid_typedef_size;
        seek( $fpGID, $gid_file_offset, SEEK_SET );
        read( $fpGID, my $gid_buffer, $gid_typedef_size ) == $gid_typedef_size
          || die
          "error reading $db_location/$db_name.$chr.gid at address $gid_file_offset\n";
        push @{ $records{'ref_gene'} }, unpack( $gid_typedef, $gid_buffer );

        #
        # strand
        #
        push @{ $records{'strand'} }, ( $tmp[1] < 5 ) ? '+' : '-';

        #
        # codon and position within codon
        #
        if ( $tmp[2] > 0 ) {
          my $codon_pos = ( int( ( $tmp[2] - 1 ) / 64 ) ) + 1;
          my $codon_code = ( $tmp[2] - 1 ) % 64;
          my ( $codon, $refbase );
          for ( my $i = 16; $i >= 1; $i /= 4 ) {
            $codon .= int( $codon_code / $i );
            $codon_code = $codon_code % $i;
          }
          $codon =~ tr/0123/ACGT/;
          my @codon = split( //, $codon );
          push @{ $records{'refbase'} },   $codon[ $codon_pos - 1 ];
          push @{ $records{'codon'} },     $codon;
          push @{ $records{'codon_pos'} }, $codon_pos;

        }

        #
        # AA and AA position
        #
        if ( $tmp[3] > 0 ) {
          push @{ $records{'aa_pos'} }, $tmp[3];
          push @{ $records{'aa_site'} },
            int( ( $tmp[3] * 3 ) + int( ( $tmp[2] - 1 ) / 64 ) + 1 - 3 );
        }
        push @{ $records{'err'} },       $tmp[4];
        push @{ $records{'gene_name'} }, $tmp[5];
        push @{ $records{'sha1_hex'} },  $tmp[6];
        $dat_record_len -= $dat_typedef_size;
        $pos++;
      }
    }

    #
    # read snp file
    #
    if ( $snp_record_len > 0 ) {
      seek( $fpSNP, $snp_file_offset, SEEK_SET );
      while ( $snp_record_len > 0 ) {
        read( $fpSNP, my $snp_buffer, $snp_typedef_size ) == $snp_typedef_size
          || die "error reading $db_location/$db_name.$chr.snp at address $snp_file_offset";
        my @tmp = unpack( $snp_typedef, $snp_buffer );
        push @{ $records{'snp_id'} }, "rs" . $tmp[0];
        push @{ $records{'het_rate'} }, sprintf( "%0.4f", eval( ( $tmp[1] - 1 ) / 199 ) )
          if ( $tmp[1] > 0 );
        push @{ $records{'orientation'} }, ( $tmp[2] == 1 ? "+" : "-" ) if ( $tmp[2] > 0 );
        $snp_record_len -= $snp_typedef_size;
      }
    }
    print $json->pretty(1)->encode( \%records ) if (%records);
  }
}
