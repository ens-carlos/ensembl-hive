#!/usr/bin/env perl

# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# Copyright [2016-2017] EMBL-European Bioinformatics Institute
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


use strict;
use warnings;

use Getopt::Long qw(:config pass_through);
use File::Temp qw/tempfile/;                # temporary local file to compare to the expected diagram
use Test::File::Contents;                   # import file_contents_eq_or_diff()
use Test::More;

use Bio::EnsEMBL::Hive::Utils::Config;      # for Bio::EnsEMBL::Hive::Utils::Config->default_system_config
use Bio::EnsEMBL::Hive::Utils::Test qw(init_pipeline runWorker beekeeper visualize_jobs generate_graph run_sql_on_db get_test_url_or_die);

# eHive needs this to initialize the pipeline (and run db_cmd.pl)
$ENV{'EHIVE_ROOT_DIR'} ||= File::Basename::dirname( File::Basename::dirname( File::Basename::dirname( Cwd::realpath($0) ) ) );

my ($generate_files, $generate_format, $gg, $test_name) = (0, 'dot', 0, 'long_mult');

GetOptions(         # Example: "visualize_jobs.t -generate -format png" would yield a visualized walk-through
    'name=s'    => \$test_name,
    'generate!' => \$generate_files,
    'format=s'  => \$generate_format,
    'gg!'       => \$gg,
);

my %vj_url = ();

my $ref_output_location = $ENV{'EHIVE_ROOT_DIR'}.'/t/03.scripts/visualize_jobs';

# A temporary file to store the output of generate_graph.pl
my ($fh, $generated_diagram_filename) = tempfile(UNLINK => 1);
close($fh);


# -------------------------[helper subroutines to create a more flexible & readable plan:]------------------------------------

sub i {
    my ($idx, $module_name, $options_cb, $tweaks_cb) = @_;

    return [ 'INIT', $idx, $module_name, $options_cb, $tweaks_cb ];
}

sub w {
    my ($job_id, $idx) = @_;

    return [ 'WORKER', $idx, $job_id ];
}

sub b {
    my ($bk_options, $idx) = @_;

    return [ 'BEEKEEPER', $idx, $bk_options ];
}

sub z {             # BEWARE: you can't call your function s() !
    my ($idx) = @_;

    return [ 'SNAPSHOT', $idx ];
}

# -----------------------------------------------------------------------------------------------------------------------------


my $name_2_plan = {
    'long_mult' => [
            i(0, 'Bio::EnsEMBL::Hive::Examples::LongMult::PipeConfig::LongMult_conf', [ -hive_force_init => 1 ], [ 'pipeline.param[take_time]=0' ]),

                                                                            z(),    # take one snapshot before running anything
            w(1),           b([qw(-analyses_pattern add_together -sync)]),  z(),    # run one job and only sync a specific analysis
            w(2),           b([qw(-sync)]),                                 z(),    # run another and sync the whole Hive
            w(4),                                                           z(),    # run, but don't sync
            w(10),  w(11),                                                  z(),
            w(5),   w(6),                                                   z(),
            w(8),   w(12),  b([qw(-analyses_pattern add_together -sync)]),  z(),
            w(9),           b([qw(-analyses_pattern add_together -sync)]),  z(),
            w(7),           b([qw(-sync)]),                                 z(),
            w(3),           b([qw(-sync)]),                                 z(),
    ],
    'long_mult_client_server' => [
            i(1, 'Bio::EnsEMBL::Hive::Examples::LongMult::PipeConfig::LongMultServer_conf', [ -hive_force_init => 1 ], [ 'pipeline.param[take_time]=0' ] ),
            i(0, 'Bio::EnsEMBL::Hive::Examples::LongMult::PipeConfig::LongMultClient_conf', sub { return [ -hive_force_init => 1, -server_url => $vj_url{1} ] }, [ 'pipeline.param[take_time]=0' ] ),

                                                                                    z(0),
            w(1, 0),                                                                z(0),
            w(3, 0), w(4, 0),                                                       z(0),
            w(2, 0),          b([qw(-analyses_pattern take_b_apart -sync)], 0),     z(0),
            w(2, 1), w(3, 1),                                                       z(0),
            w(5, 0), w(4, 1),                                                       z(0),
            w(1, 1),                                                                z(0),
            w(5, 1), w(7, 0), b([qw(-sync)], 1), b([qw(-sync)], 0),                 z(0),
            w(6, 0),                                                                z(0),
    ],
};

my @test_names_to_run = ($test_name eq '*') ? keys %$name_2_plan : ( $test_name );

foreach my $test_name (@test_names_to_run) {
    subtest $test_name, sub {

        my $ref_directory   = "${ref_output_location}/${test_name}";
        if($generate_files) {
            system('mkdir', '-p', $ref_directory);
        }

        my $plan        = $name_2_plan->{$test_name};
        my $step_number = 0;

        %vj_url = ();

        foreach my $op_vector (@$plan) {

            my ($op_type, $op_idx, $op_extras) = @$op_vector;

            $op_idx //= 0;
            my $op_url = $vj_url{$op_idx};
            
            if($op_type eq 'INIT') {
                my ($op_type, $idx, $module_name, $options_cb, $tweaks_cb) = @$op_vector; # more parameters

                $vj_url{$idx} = get_test_url_or_die(-tag => 'vj_'.$idx, -no_user_prefix => 1);

                init_pipeline($module_name, $vj_url{$idx}, (ref($options_cb) eq 'CODE') ? &$options_cb() : $options_cb, (ref($tweaks_cb) eq 'CODE') ? &$tweaks_cb() : $tweaks_cb);

            } elsif( $op_type eq 'WORKER' ) {
                runWorker($op_url, [ -job_id => $op_extras ] );

            } elsif( $op_type eq 'BEEKEEPER' ) {
                beekeeper($op_url, $op_extras);

            } elsif( $op_type eq 'SNAPSHOT' ) {

                ++$step_number;

                visualize_jobs( $op_url, [ -accu_values,
                                           -include,
                                            ($generate_format eq 'dot')
                                                ? (
                                                    -output => '/dev/null',
                                                    -format => 'canon',
                                                    -dot_input => $generated_diagram_filename,
                                                    # -config_file => Bio::EnsEMBL::Hive::Utils::Config->default_system_config,     ## FIXME: not supported yet
                                                ) : (
                                                    -format => $generate_format,
                                                    -output => $generated_diagram_filename,
                                                ),
                                         ], "Generated a '$generate_format' J-diagram for pipeline '$test_name', step $step_number, with accu values" );

                my $ref_jdiag_filename  = sprintf("%s/%s_jobs_%02d.%s", $ref_directory, $test_name, $step_number, $generate_format);

                if($generate_files) {
                    system('cp', '-f', $generated_diagram_filename, $ref_jdiag_filename);
                } else {
                    files_eq_or_diff($generated_diagram_filename, $ref_jdiag_filename);
                }

                if($gg) {
                    generate_graph( $op_url, [
                                                ($generate_format eq 'dot')
                                                    ? (
                                                        -output => '/dev/null',
                                                        -format => 'canon',
                                                        -dot_input => $generated_diagram_filename,
                                                        -config_file => Bio::EnsEMBL::Hive::Utils::Config->default_system_config,   # to ensure JSON Config-independent reproducibility
                                                    ) : (
                                                        -format => $generate_format,
                                                        -output => $generated_diagram_filename,
                                                    ),
                                             ], "Generated a '$generate_format' A-diagram for pipeline '$test_name', step $step_number, with accu values" );

                    my $ref_adiag_filename  = sprintf("%s/%s_analyses_%02d.%s", $ref_directory, $test_name, $step_number, $generate_format);

                    if($generate_files) {
                        system('cp', '-f', $generated_diagram_filename, $ref_adiag_filename);
                    } else {
                        files_eq_or_diff($generated_diagram_filename, $ref_adiag_filename);
                    }
                }

            } else {
                die "Cannot parse the plan: operation '$op_type' is not recognized";
            }
        }

        foreach my $url (values %vj_url) {
            run_sql_on_db($url, 'DROP DATABASE');
        }

    } # subtest
} # foreach $test_name


done_testing();
