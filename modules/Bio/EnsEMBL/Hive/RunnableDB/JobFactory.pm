=pod 

=head1 NAME

    Bio::EnsEMBL::Hive::RunnableDB::JobFactory

=head1 SYNOPSIS

    standaloneJob.pl Bio::EnsEMBL::Hive::RunnableDB::JobFactory \
                    --inputcmd 'cd ${ENSEMBL_CVS_ROOT_DIR}/ensembl-hive/modules/Bio/EnsEMBL/Hive/RunnableDB; ls -1 *.pm' \
                    --flow_into "{ 2 => { 'mysql://ensadmin:${ENSADMIN_PSW}@127.0.0.1:2914/lg4_compara_families_70/meta' => {'meta_key'=>'module_name','meta_value'=>'#_0#'} } }""

=head1 DESCRIPTION

    This is a generic RunnableDB module for creating batches of similar jobs using dataflow mechanism
    (a fan of jobs is created in one branch and the funnel in another).
    Make sure you wire this buliding block properly from outside.

    You can supply as parameter one of 4 sources of ids from which the batches will be generated:

        param('inputlist');  The list is explicitly given in the parameters, can be abbreviated: 'inputlist' => ['a'..'z']

        param('inputfile');  The list is contained in a file whose name is supplied as parameter: 'inputfile' => 'myfile.txt'

        param('inputquery'); The list is generated by an SQL query (against the production database by default) : 'inputquery' => 'SELECT object_id FROM object WHERE x=y'

        param('inputcmd');   The list is generated by running a system command: 'inputcmd' => 'find /tmp/big_directory -type f'

    NB for developpers: fetch_input() method is intentionally missing from JobFactory.pm .
    If JobFactory is subclassed (say, by a Compara RunnableDB) the child class's should use fetch_input()
    to set $self->param('inputlist') to whatever list of ids specific to that particular type of data (slices, members, etc).
    The rest functionality will be taken care for by the parent class code.

=head1 LICENSE

    Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

    Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

         http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software distributed under the License
    is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and limitations under the License.

=head1 CONTACT

    Please subscribe to the Hive mailing list:  http://listserver.ebi.ac.uk/mailman/listinfo/ehive-users  to discuss Hive-related questions or to be notified of our updates

=cut


package Bio::EnsEMBL::Hive::RunnableDB::JobFactory;

use strict;
use warnings;

use base ('Bio::EnsEMBL::Hive::Process');


sub param_defaults {
    return {
        'column_names'      => 0,
        'delimiter'         => undef,
        'randomize'         => 0,
        'step'              => 0,
        'key_column'        => 0,
        'input_id'          => 0,   # this parameter is no longer supported and should stay at 0

        'inputlist'         => undef,
        'inputfile'         => undef,
        'inputquery'        => undef,
        'inputcmd'          => undef,

        'fan_branch_code'   => 2,
    };
}



=head2 run

    Description : Implements run() interface method of Bio::EnsEMBL::Hive::Process that is used to perform the main bulk of the job (minus input and output).

    param('column_names'):  Controls the column names that come out of the parser: 0 = "no names", 1 = "parse names from data", arrayref = "take names from this array"

    param('delimiter'): If you set it your lines in file/cmd mode will be split into columns that you can use individually when constructing the input_id_template hash.

    param('randomize'): Shuffles the rows before creating jobs - can sometimes lead to better overall performance of the pipeline. Doesn't make any sence for minibatches (step>1).

    param('step'):      The requested size of the minibatch (1 by default). The real size of a range may be smaller than the requested size.

    param('key_column'): If every line of your input is a list (it happens, for example, when your SQL returns multiple columns or you have set the 'delimiter' in file/cmd mode)
                         this is the way to say which column is undergoing 'ranging'


        # The following 4 parameters are mutually exclusive and define the source of ids for the jobs:

    param('inputlist');  The list is explicitly given in the parameters, can be abbreviated: 'inputlist' => ['a'..'z']

    param('inputfile');  The list is contained in a file whose name is supplied as parameter: 'inputfile' => 'myfile.txt'

    param('inputquery'); The list is generated by an SQL query (against the production database by default) : 'inputquery' => 'SELECT object_id FROM object WHERE x=y'

    param('inputcmd');   The list is generated by running a system command: 'inputcmd' => 'find /tmp/big_directory -type f'

=cut

sub run {
    my $self = shift @_;

    my $column_names    = $self->param('column_names');   # can be 0 (no names), 1 (names from data) or an arrayref (names from this array)
    my $delimiter       = $self->param('delimiter');

    my $randomize       = $self->param('randomize');

        # minibatching-related:
    my $step            = $self->param('step');
    my $key_column      = $self->param('key_column');

    my $inputlist       = $self->param('inputlist');
    my $inputfile       = $self->param('inputfile');
    my $inputquery      = $self->param('inputquery');
    my $inputcmd        = $self->param('inputcmd');

    my $parse_column_names = $column_names && (ref($column_names) ne 'ARRAY');

    my ($rows, $column_names_from_data) =
              $inputlist    ? $self->_get_rows_from_list(  $inputlist  )
            : $inputquery   ? $self->_get_rows_from_query( $inputquery )
            : $inputfile    ? $self->_get_rows_from_open(  $inputfile  , $delimiter, $parse_column_names )
            : $inputcmd     ? $self->_get_rows_from_open( "$inputcmd |", $delimiter, $parse_column_names )
            : die "range of values should be defined by setting 'inputlist', 'inputquery', 'inputfile' or 'inputcmd'";

    if( $column_names_from_data                                             # column data is available
    and ( defined($column_names) ? (ref($column_names) ne 'ARRAY') : 1 )    # and is badly needed
    ) {
        $column_names = $column_names_from_data;
    }
    # after this point $column_names should either contain a list or be false

    if( $self->param('input_id') ) {
        die "'input_id' is no longer supported, please reconfigure as the input_id_template of the dataflow_rule";
    }

    if($randomize) {
        _fisher_yates_shuffle_in_place($rows);
    }

    my $output_ids = $step
        ? $self->_substitute_minibatched_rows($rows, $column_names, $step, $key_column)
        : $self->_substitute_rows($rows, $column_names);

    $self->param('output_ids', $output_ids);
}


=head2 write_output

    Description : Implements write_output() interface method of Bio::EnsEMBL::Hive::Process that is used to deal with job's output after the execution.
                  Here we rely on the dataflow mechanism to create jobs.

    param('fan_branch_code'): defines the branch where the fan of jobs is created (2 by default).

=cut

sub write_output {  # nothing to write out, but some dataflow to perform:
    my $self = shift @_;

    my $output_ids              = $self->param('output_ids');
    my $fan_branch_code         = $self->param('fan_branch_code');

        # "fan out" into fan_branch_code:
    $self->dataflow_output_id($output_ids, $fan_branch_code);
}


################################### main functionality starts here ###################


=head2 _get_rows_from_list
    
    Description: a private method that ensures the list is 2D

=cut

sub _get_rows_from_list {
    my ($self, $inputlist) = @_;

    return ref($inputlist->[0])
        ? $inputlist
        : [ map { [ $_ ] } @$inputlist ];
}


=head2 _get_rows_from_query
    
    Description: a private method that loads ids from a given sql query

    param('db_conn'): An optional hash to pass in connection parameters to the database upon which the query will have to be run.

=cut

sub _get_rows_from_query {
    my ($self, $inputquery) = @_;

    if($self->debug()) {
        warn qq{inputquery = "$inputquery"\n};
    }
    my @rows = ();
    my $sth = $self->data_dbc()->prepare($inputquery);
    $sth->execute();
    my @column_names_from_data = @{$sth->{NAME}};   # tear it off the original reference to gain some freedom

    while (my @cols = $sth->fetchrow_array()) {
        push @rows, \@cols;
    }
    $sth->finish();

    return (\@rows, \@column_names_from_data);
}


=head2 _get_rows_from_open
    
    Description: a private method that loads ids from a given file or command pipe

=cut

sub _get_rows_from_open {
    my ($self, $input_file_or_pipe, $delimiter, $parse_header) = @_;

    if($self->debug()) {
        warn qq{input_file_or_pipe = "$input_file_or_pipe"\n};
    }
    my @rows = ();
    open(FILE, $input_file_or_pipe) or die "Could not open '$input_file_or_pipe' because: $!";
    while(my $line = <FILE>) {
        chomp $line;

        push @rows, [ defined($delimiter) ? split(/$delimiter/, $line) : $line ];
    }
    close FILE;
    my $exit = $? >> 8;
    die "Could not read from '$input_file_or_pipe'. Received the error $exit\n" if $exit;

    my $column_names_from_data = $parse_header ? shift @rows : 0;

    return (\@rows, $column_names_from_data);
}


=head2 _substitute_rows

    Description: a private method that goes through a list and transforms every row into a hash

=cut

sub _substitute_rows {
    my ($self, $rows, $column_names) = @_;

    my @hashes = ();

    foreach my $row (@$rows) {
        my $job_param_hash =  $column_names
            ?  {              map { ($column_names->[$_] => $row->[$_]) } (0..scalar(@$row)-1) }
            :  { '_' => $row, map { ("_$_"               => $row->[$_]) } (0..scalar(@$row)-1) };

        push @hashes, $job_param_hash;
    }
    return \@hashes;
}


=head2 _substitute_minibatched_rows
    
    Description: a private method that minibatches a list and transforms every minibatch using param-substitution

=cut

sub _substitute_minibatched_rows {
    my ($self, $rows, $column_names, $step, $key_column) = @_;

    my @ranges = ();

    while(@$rows) {
        my $start_row  = shift @$rows;
        my $range_start = $start_row->[$key_column];

        my $range_end   = $range_start;
        my $range_count = 1;
        my $next_row    = $start_row; # safety, in case the internal while doesn't execute even once

        while($range_count<$step && @$rows) {
               $next_row    = shift @$rows;
            my $next_value  = $next_row->[$key_column];

            my $predicted_next = $range_end;
            if(++$predicted_next eq $next_value) {
                $range_end = $next_value;
                $range_count++;
            } else {
                unshift @$rows, $next_row;
                last;
            }
        }

        my $job_range = {
            '_range_start'  => $range_start,
            '_range_end'    => $range_end,
            '_range_count'  => $range_count,

            $column_names
                ?  map { ('_start_'.$column_names->[$_] => $start_row->[$_], '_end_'.$column_names->[$_] => $next_row->[$_]) } (0..scalar(@$start_row)-1)
                :  map { ("_start_$_"                   => $start_row->[$_], "_end_$_"                   => $next_row->[$_]) } (0..scalar(@$start_row)-1)
        };
        push @ranges, $job_range;
    }
    return \@ranges;
}


=head2 _fisher_yates_shuffle_in_place
    
    Description: a private function (not a method) that shuffles a list of ids

=cut

sub _fisher_yates_shuffle_in_place {
    my $array = shift @_;

    for(my $upper=scalar(@$array);--$upper;) {
        my $lower=int(rand($upper+1));
        next if $lower == $upper;
        @$array[$lower,$upper] = @$array[$upper,$lower];
    }
}

1;
