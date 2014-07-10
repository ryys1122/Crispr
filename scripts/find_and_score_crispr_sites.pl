#!/usr/bin/env perl
use warnings; use strict;
# use MODULES
use autodie;
use Getopt::Long;
use Pod::Usage;
use Readonly;
use List::MoreUtils qw( none );

use Bio::EnsEMBL::Registry;
use Bio::Seq;
use Bio::SeqIO;

use Data::Dumper;
use English qw( -no_match_vars );

use Crispr::Target;
use Crispr::crRNA;
use Crispr;

# option variables
my %options;
get_and_check_options();

#get current date
use DateTime;
my $date_obj = DateTime->now();
my $todays_date = $date_obj->ymd;

# check registry file
if( $options{registry_file} ){
    Bio::EnsEMBL::Registry->load_all( $options{registry_file} );
}
else{
    # if no registry file connect anonymously to the public server
    Bio::EnsEMBL::Registry->load_registry_from_db(
      -host    => 'ensembldb.ensembl.org',
      -user    => 'anonymous',
      -port    => 5306,
    );
}
my $ensembl_version = Bio::EnsEMBL::ApiVersion::software_version();

# Ensure database connection isn't lost; Ensembl 64+ can do this more elegantly
## no critic (ProhibitMagicNumbers)
if ( $ensembl_version < 64 ) {
## use critic
    Bio::EnsEMBL::Registry->set_disconnect_when_inactive();
}
else {
    Bio::EnsEMBL::Registry->set_reconnect_when_lost();
}

#get adaptors
my $gene_adaptor = Bio::EnsEMBL::Registry->get_adaptor( $options{species}, 'core', 'gene' );
my $exon_adaptor = Bio::EnsEMBL::Registry->get_adaptor( $options{species}, 'Core', 'Exon' );
my $slice_adaptor = Bio::EnsEMBL::Registry->get_adaptor( $options{species}, 'core', 'slice' );
my $transcript_adaptor = Bio::EnsEMBL::Registry->get_adaptor( $options{species}, 'core', 'transcript' );

# open filehandles for off_target fasta files
my $basename = $todays_date;
$basename =~ s/\A/$options{file_base}_/xms if( $options{file_base} );

# make new design object
my $crispr_design = Crispr->new(
    species => $options{species},
    target_seq => $options{target_seq},
    target_genome => $options{target_genome},
    annotation_file => $options{annotation_file},
    slice_adaptor => $slice_adaptor,
    debug => $options{debug},
);
if( defined $options{num_five_prime_Gs} ){
    $crispr_design->five_prime_Gs( $options{num_five_prime_Gs} );
}

warn "Reading input...\n" if $options{verbose};
while(<>){
    chomp;
    s/,//xmsg;
    
    my $rv;
    my @columns = split /\t/xms;
    # guess id type
    $rv =   ($columns[0] =~ m/\AENS[A-Z]*G[0-9]{11}# gene id/xms
            ||
            $columns[0] =~ m/\ALRG_[0-9]+/xms )     ?   get_gene( @columns )
        :   $columns[0] =~ m/\AENS[A-Z]*E[0-9]{11}# exon id/xms ? get_exon( @columns )
        :   $columns[0] =~ m/\AENS[A-Z]*T[0-9]{11}# transcript id/xms   ?   get_transcript( @columns )
        :   $columns[0] =~ m/\A[\w.]+:\d+\-\d+[:0-1-]*# position/xms    ?   get_posn( @columns )
        :                                                                   "Couldn't match input type: " . join("\t", @columns,) . ".\n";
        ;
    
    if( $rv =~ m/\ACouldn't\smatch/xms ){
        die $rv;
    }
}

if( !@{ $crispr_design->targets } ){
    die "No Targets!\n";
}

if( $options{debug} ){
    map {   print join("\t", $_->name, $_->gene_id, );
            if( $_->crRNAs){ print "\t", scalar @{$_->crRNAs} } print "\n"
        } @{$crispr_design->targets};
}

# score crRNAs
if( $options{no_crRNA} ){
    print "Skipping Scoring Off-Targets...\n" if $options{verbose};    
    print "Skipping Scoring Coding scores...\n" if $options{verbose};    
}
else{
    foreach my $target ( @{ $crispr_design->targets } ){
        if( !@{$target->crRNAs} ){
            #remove from targets if there are no crispr sites for that target
            $crispr_design->remove_target( $target );
        }
    }
    print "Scoring Off-Targets...\n" if $options{verbose};
    $crispr_design->off_targets_bwa( $crispr_design->all_crisprs, $basename, );
    
    if( $options{coding} ){
        warn "Calculating coding scores...\n" if $options{verbose};
        foreach my $target ( @{ $crispr_design->targets } ){
            foreach my $crRNA ( @{$target->crRNAs} ){
                if( $crRNA->target && $crRNA->target_gene_id ){
                    my $transcripts;
                    my $gene_id = $crRNA->target_gene_id;
                    my $gene = $gene_adaptor->fetch_by_stable_id( $gene_id );
                    $transcripts = $gene->get_all_Transcripts;
                    $crRNA = $crispr_design->calculate_all_pc_coding_scores( $crRNA, $transcripts );
                }
            }
        }
    }
}

warn "Outputting results...\n" if $options{verbose};
Readonly my @columns => (
    qw{ target_id name assembly chr start end strand
        species requires_enzyme gene_id gene_name requestor ensembl_version
        designed crRNA_name chr start end strand score sequence oligo1 oligo2
        off_target_score bwa_score bwa_hits NULL NULL
        coding_score coding_scores_by_transcript five_prime_Gs plasmid_backbone }
);

if( $options{no_crRNA} ){
    print '#', join("\t", @columns[0..13] ), "\n";
}
else{
    print join("\t", @columns ), "\n";    
}
foreach my $target ( @{ $crispr_design->targets } ){
    if( $options{no_crRNA} ){
        print join("\t", $target->info ), "\n";
    }
    else{
        foreach my $crRNA ( sort { $b->score <=> $a->score } @{$target->crRNAs} ){        
            # output
            print join("\t",
                $crRNA->target_info_plus_crRNA_info,
            ), "\t";
            # check composition
            my $sequence = substr($crRNA->sequence, 0, 20 );
            my $A_count = $sequence =~ tr/A//;
            my $C_count = $sequence =~ tr/C//;
            my $G_count = $sequence =~ tr/G//;
            my $T_count = $sequence =~ tr/T//;
            my $not_ideal = 0;
            foreach my $count ( $A_count, $C_count, $G_count, $T_count ){
                if( $count/20 < 0.1 || $count/20 > 0.4 ){
                    $not_ideal = 1;
                }
            }
            if( $not_ideal ){
                print "Base Composition is not ideal!\n";
            }
            else{
                print "\n";
            }
        }
    }
}

sub get_exon {
    my ( $exon_id, $requestor ) = @_;
    my $success = 0;
    if( !$requestor ){
        die "Need a requestor for each exon!\n";
    }
    $requestor =~ s/'//xmsg;
    # get exon object
    my $exon = $exon_adaptor->fetch_by_stable_id( $exon_id );
    my ( $chr, $gene, );
    if( $exon ){
        $chr = $exon->seq_region_name;
        # get gene id and transcripts
        $gene = $gene_adaptor->fetch_by_exon_stable_id( $exon_id );
        my $target = Crispr::Target->new(
            name => $exon_id,
            assembly => $options{assembly},
            chr => $chr,
            start => $exon->seq_region_start,
            end => $exon->seq_region_end,
            strand => $exon->seq_region_strand,
            species => $options{species},
            gene_id => $gene->stable_id,
            gene_name => $gene->external_name,
            requestor => $requestor,
            ensembl_version => $ensembl_version,
        );
        
        if( $options{no_crRNA} ){
            $crispr_design->add_target( $target );
        }
        else{
            if( $options{enzyme} ){
                $target->requires_enzyme( $options{enzyme} );
            }
            my $crRNAs = [];
            eval{
                $crRNAs = $crispr_design->find_crRNAs_by_target( $target, );
            };
            if( $EVAL_ERROR && $EVAL_ERROR =~ m/seen/xms ){
                $success = 1;
                warn join(q{ }, $EVAL_ERROR, "Skipping...\n", );
            }
            elsif( $EVAL_ERROR ){
                die $EVAL_ERROR;
            }
            if( scalar @{$crRNAs} ){
                $success = 1;
            }
            else{
                warn "No crRNAs for ", $target->name, "\n";
                $crispr_design->remove_target( $target );
            }
        }
    }
    else{
        warn "Couldn't get exon for id:$exon_id.\n";
        $success = 1;
    }
    return $success;
}

sub get_gene {
    my ( $gene_id, $requestor ) = @_;
    my $success = 0;
    if( !$requestor ){
        die "Need a requestor for each position!\n";
    }
    $requestor =~ s/'//xmsg;
    #get gene
    my $gene = $gene_adaptor->fetch_by_stable_id( $gene_id );
    
    if( $gene ){
        # check for LRG_genes
        if( $gene->biotype eq 'LRG_gene' ){
            # get corresponding non-LRG gene
            my $genes = $gene_adaptor->fetch_all_by_external_name( $gene->external_name );
            my @genes = grep { $_->stable_id !~ m/\ALRG/xms } @{$genes};
            if( scalar @genes == 1 ){
                warn join(q{ }, 'Converted LRG gene,', $gene->stable_id, 'to', $genes[0]->stable_id, ), "\n";
                $gene = $genes[0];
            }
            else{
                warn "Could not find a single corresponding gene for LRG gene, ", $gene->stable_id, " got:",
                    map { $_->stable_id } @genes,
                    "\n";
            }
        }
        # get transcripts
        my $transcripts = $gene->get_all_Transcripts();
        
        foreach my $transcript ( @{$transcripts} ){
            ## check whether transcript is protein-coding
            #next if( $transcript->biotype() ne 'protein_coding' );
            # get all exons
            my $exons = $transcript->get_all_Exons();
            
            foreach my $exon ( @{$exons} ){
                my $target = Crispr::Target->new(
                    name => $exon->stable_id,
                    assembly => $options{assembly},
                    chr => $exon->seq_region_name,
                    start => $exon->seq_region_start,
                    end => $exon->seq_region_end,
                    strand => $exon->seq_region_strand,
                    species => $options{species},
                    gene_id => $gene->stable_id,
                    gene_name => $gene->external_name,
                    requestor => $requestor,
                    ensembl_version => $ensembl_version,
                );
                
                if( $options{no_crRNA} ){
                    $crispr_design->add_target( $target );
                }
                else{
                    if( $options{enzyme} ){
                        $target->requires_enzyme( $options{enzyme} );
                    }
                    my $crRNAs = [];
                    eval{
                        $crRNAs = $crispr_design->find_crRNAs_by_target( $target, );
                    };
                    if( $EVAL_ERROR && $EVAL_ERROR =~ m/seen/xms ){
                        warn join(q{ }, $EVAL_ERROR, "Skipping...\n", );
                    }
                    elsif( $EVAL_ERROR ){
                        die $EVAL_ERROR;
                    }
                    if( scalar @{$crRNAs} ){
                        $success = 1;
                    }
                    else{
                        warn "No crRNAs for ", $target->name, "\n";
                        $crispr_design->remove_target( $target );
                    }
                }
            }
        }
    }
    else{
        warn "Couldn't get gene for id:$gene_id.\n";
        $success = 1;
    }
    return $success;
}

sub get_transcript {
    my ( $transcript_id, $requestor ) = @_;
    my $success = 0;
    if( !$requestor ){
        die "Need a requestor for each transcript!\n";
    }
    $requestor =~ s/'//xmsg;
    #get gene
    my $transcript = $transcript_adaptor->fetch_by_stable_id( $transcript_id );
    if( $options{debug} ){
        if( $transcript ){
            warn join("\t", $transcript->stable_id, );
        }
    }
    my $gene = $transcript->get_Gene;
    
    if( $transcript ){
        my $exons = $transcript->get_all_Exons();
        
        foreach my $exon ( @{$exons} ){
            my $target = Crispr::Target->new(
                name => $exon->stable_id,
                assembly => $options{assembly},
                chr => $exon->seq_region_name,
                start => $exon->seq_region_start,
                end => $exon->seq_region_end,
                strand => $exon->seq_region_strand,
                species => $options{species},
                gene_id => $gene->stable_id,
                gene_name => $gene->external_name,
                requestor => $requestor,
                ensembl_version => $ensembl_version,
            );
            
            if( $options{no_crRNA} ){
                $crispr_design->add_target( $target );
            }
            else{
                if( $options{enzyme} ){
                    $target->requires_enzyme( $options{enzyme} );
                }
                my $crRNAs = [];
                eval{
                    $crRNAs = $crispr_design->find_crRNAs_by_target( $target, );
                };
                if( $EVAL_ERROR && $EVAL_ERROR =~ m/seen/xms ){
                    warn join(q{ }, $EVAL_ERROR, "Skipping...\n", );
                }
                elsif( $EVAL_ERROR ){
                    die $EVAL_ERROR;
                }
                if( scalar @{$crRNAs} ){
                    $success = 1;
                }
                else{
                    warn "No crRNAs for ", $target->name, "\n";
                    $crispr_design->remove_target( $target );
                }
            }
        }
    }
    else{
        warn "Couldn't get transcript for id:$transcript_id.\n";
        $success = 1;
    }
    return $success;
}

sub get_posn {
    my ( $posn, $requestor, $gene_id  ) = @_;
    my $success = 0;
    if( !$requestor ){
        die "Need a requestor for each position!\n";
    }
    $requestor =~ s/'//xmsg;
    
    my ( $chr, $position, $strand, ) =  split /:/, $posn;
    if( !$chr || !$position ){
        die "Need at least a chr and position ( chr:position )\n";
    }
    my ( $start_position, $end_position );
    if( $position =~ m/-/ ){
        my @posns = split /-/, $position;
        $start_position = $posns[0];
        $end_position = $posns[1];
    }
    else{
        $start_position = $position;
        $end_position = $position;
    }
    if( !$strand ){
        $strand = 1;
    }
    my $target_name = $chr . ":" . $start_position . "-" . $end_position . ":" . $strand;
    
    # get slice for position and get genes and transcripts that overlap posn
    my $slice = $slice_adaptor->fetch_by_region( 'toplevel', $chr, $start_position, $end_position, $strand );
    
    if( $slice ){
        my $gene;
        if( $gene_id ){
            if( $gene_id !~ m/\AENS[A-Z]*G[0-9]+\z/xms ){
                die join(" ", $gene_id, "is not a valid gene id.", ), "\n";
            }
            # get gene from gene id and get transcripts
            $gene = $gene_adaptor->fetch_by_stable_id( $gene_id );
        }
        else{
            my $genes = $gene_adaptor->fetch_all_by_Slice( $slice );
            if( scalar @$genes == 1 ){
                $gene = $genes->[0];
            }
        }
        
        my $target = Crispr::Target->new(
            name => $target_name,
            assembly => $options{assembly},
            chr => $chr,
            start => $start_position,
            end => $end_position,
            strand => $strand,
            species => $options{species},
            gene_id => $gene->stable_id,
            gene_name => $gene->external_name,
            requestor => $requestor,
            ensembl_version => $ensembl_version,
        );
        
        if( $options{no_crRNA} ){
            $crispr_design->add_target( $target );
        }
        else{
            if( $options{enzyme} ){
                $target->requires_enzyme( $options{enzyme} );
            }
            my $crRNAs = [];
            eval{
                $crRNAs = $crispr_design->find_crRNAs_by_target( $target, );
            };
            if( $EVAL_ERROR && $EVAL_ERROR =~ m/seen/xms ){
                warn join(q{ }, $EVAL_ERROR, "Skipping...\n", );
            }
            if( scalar @{$crRNAs} ){
                $success = 1;
            }
            else{
                warn "No crRNAs for ", $target->name, "\n";
                $crispr_design->remove_target( $target );
            }
        }
    }
    else{
        warn "Couldn't get gene for id:$gene_id.\n";
        $success = 1;
    }
    return $success;
}


sub get_and_check_options {
    
    GetOptions(
        \%options,
        'registry=s',
        'species=s',
        'assembly=s',
        'target_genome=s',
        'annotation_file=s',
        'enzyme+',
        'target_sequence=s',
        'num_five_prime_Gs=i',
        'coding',
        'file_base=s',
        'no_crRNA',
        'help',
        'man',
        'debug+',
        'verbose',
    ) or pod2usage(2);
    
    # Documentation
    if( $options{help} ) {
        pod2usage(1);
    }
    elsif( $options{man} ) {
        pod2usage( -verbose => 2 );
    }
    
    if( !$options{target_genome} && $options{species} ){
        $options{target_genome} = $options{species} eq 'zebrafish'    ?  '/lustre/scratch110/sanger/rw4/genomes/Dr/Zv9/striped/zv9_toplevel_unmasked.fa'
            :               $options{species} eq 'mouse'     ?   '/lustre/scratch110/sanger/rw4/genomes/Mm/e70/striped/Mus_musculus.GRCm38.70.dna.noPATCH.fa'
            :               $options{species} eq 'human'     ?   '/lustre/scratch110/sanger/rw4/genomes/Hs/GRCh37_70/striped/Homo_sapiens.GRCh37.70.dna.noPATCH.fa'
            :                                           undef
        ;
    }
    elsif( $options{target_genome} && !$options{species} ){
        $options{species} = $options{target_genome} eq '/lustre/scratch110/sanger/rw4/genomes/Dr/Zv9/striped/zv9_toplevel_unmasked.fa'     ?   'zebrafish'
        :           $options{target_genome} eq '/lustre/scratch110/sanger/rw4/genomes/Mm/e70/striped/Mus_musculus.GRCm38.70.dna.noPATCH.fa'      ?   'mouse'
        :           $options{target_genome} eq '/lustre/scratch110/sanger/rw4/genomes/Hs/GRCh37_70/striped/Homo_sapiens.GRCh37.70.dna.noPATCH.fa'    ? 'human'
        :                                                                                                                     undef
        ;
    }
    elsif( !$options{target_genome} && !$options{species} ){
        pod2usage( "Must specify at least one of --target_genome and --species!\n." );
    }
    
    if( defined $options{num_five_prime_Gs} ){
        if( none { $_ == $options{num_five_prime_Gs} } ( 0, 1, 2 ) ){
            pod2usage("option --num_five_prime_Gs must be one of 0, 1 or 2!\n");
        }
    }
    
    my $five_prime_Gs_in_target_seq;
    if( $options{target_seq} ){
        # check target sequence is 23 bases long
        if( length $options{target_seq} != 23 ){
            pod2usage("Target sequence must be 23 bases long!\n");
        }
        if( $options{target_seq} =~ m/\A(G*) # match Gs at the start/xms ){
            $five_prime_Gs_in_target_seq = length $1;
        }
        else{
            $five_prime_Gs_in_target_seq = 0;
        }
        
        if( defined $options{num_five_prime_Gs} ){
            if( $five_prime_Gs_in_target_seq != $options{num_five_prime_Gs} ){
                pod2usage("The number of five prime Gs in target sequence, ",
                          $options{target_seq}, " doesn't match with the value of --num_five_prime_Gs option, ",
                          $options{num_five_prime_Gs}, "!\n");
            }
        }
        else{
            $options{num_five_prime_Gs} = $five_prime_Gs_in_target_seq;
        }
    }
    else{
        if( defined $options{num_five_prime_Gs} ){
            my $target_seq = 'NNNNNNNNNNNNNNNNNNNNNGG';
            my $Gs = q{};
            for ( my $i = 0; $i < $options{num_five_prime_Gs}; $i++ ){
                $Gs .= 'G';
            }
            substr( $target_seq, 0, $options{num_five_prime_Gs}, $Gs );
            #print join("\t", $Gs, $target_seq ), "\n";
            $options{target_seq} = $target_seq;
        }
        else{
            $options{target_seq} = 'GGNNNNNNNNNNNNNNNNNNNGG';
            $options{num_five_prime_Gs} = 2;
        }
    }

    $options{debug} = 0 if !$options{debug};
    
    warn "Settings:\n", map { join(' - ', $_, defined $options{$_} ? $options{$_} : 'off'),"\n" } sort keys %options if $options{verbose};
}

__END__

=pod

=head1 NAME

find_and_score_crRNAs.pl

=head1 DESCRIPTION

find_and_score_crRNAs.pl takes either an Ensembl exon id, gene id, transcript id
or a genomic position for a target and uses the Ensembl API to retrieve sequence
for the region. The region is scanned for possible crispr guideRNA targets (the
target sequence can be adjusted) and these possible crRNA targets are scored for
possible off-target effects and optionally for its position in coding transcripts.

=head1 SYNOPSIS

    find_and_score_crRNAs.pl [options] filename(s) | target info on STDIN
        --registry              a registry file for connecting to the Ensembl database
        --species               species for the targets
        --assembly              current assembly
        --target_genome         a target genome fasta file for scoring off-targets
        --annotation_file       an annotation gff file for scoring off-targets
        --target_sequence       crRNA consensus sequence (e.g. GGNNNNNNNNNNNNNNNNNNNGG)
        --num_five_prime_Gs     The number of 5' Gs present in the consensus sequence, 0,1 OR 2
        --enzyme                Sets the requires_enzyme attribute of targets [default: n]
        --coding                turns on scoring of position of site within target gene
        --file_base             a prefix for all output files
        --no_crRNA              option to supress finding and scoring crispr target sites
        --help                  prints help message and exits
        --man                   prints manual page and exits
        --debug                 prints debugging information
        --verbose               turns on verbose output

=head1 REQUIRED ARGUMENTS

=over

=item B<input>

input_file of Ensembl exon ids, gene ids, transcript ids or genomic positions.
All four types can be present in one file.
This can also be supplied on STDIN.

=back

=head1 OPTIONS

=over

=item B<--registry>

a registry file for connecting to the Ensembl database.
If no file is supplied the script connects anonymously to the current version of the database.

=item B<--species >

The relevant species for the supplied targets e.g mouse. [default: zebrafish]

=item B<--assembly >

The version of the genome assembly.

=item B<--target_genome >

The path of the target genome file. This needs to have been indexed by bwa in order to score crispr off-targets.

=item B<--annotation_file >

The path of the annotation file for the appropriate species. Must be in gff format.

=item B<--target_sequence >

The Cas9 target sequence [default: NNNNNNNNNNNNNNNNNNNNNGG ]

=item B<--num_Gs >

The numbers of Gs required at the 5' end of the target sequence.
e.g. 1 five prime G has a target sequence GNNNNNNNNNNNNNNNNNNNNGG. [default: 0]

=item B<--enzyme>

switch to indicate if a unique restriction site is required within the crispr site.

=item B<--coding>

switch to indicate whether or not to score crRNAs for position in coding transcripts

=item B<--file_base >

A prefix for all output files. This is added to output filenames with a '_' as separator.

=item B<--no_crRNA>

Option to supress finding and scoring of crRNAs for the targets.
Simply gets the information on the targets and outputs the target info.

=item B<--debug>

Print debugging information.

=item B<--verbose>

Switch to verbose output mode

=item B<--help>

Print a brief help message and exit.

=item B<--man>

Print this script's manual page and exit.

=back

=head1 AUTHOR

=over 4

=item *

Richard White <richard.white@sanger.ac.uk>

=back

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2014 by Genome Research Ltd.

This is free software, licensed under:

  The GNU General Public License, Version 3, June 2007

=cut