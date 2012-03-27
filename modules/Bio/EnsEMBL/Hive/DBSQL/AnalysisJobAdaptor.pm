# Perl module for Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor
#
# Date of creation: 22.03.2004
# Original Creator : Jessica Severin <jessica@ebi.ac.uk>
#
# Copyright EMBL-EBI 2004
#
# You may distribute this module under the same terms as perl itself

=pod

=head1 NAME

  Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor

=head1 SYNOPSIS

  $analysisJobAdaptor = $db_adaptor->get_AnalysisJobAdaptor;
  $analysisJobAdaptor = $analysisJob->adaptor;

=head1 DESCRIPTION

  Module to encapsulate all db access for persistent class AnalysisJob.
  There should be just one per application and database connection.

=head1 CONTACT

  Please contact ehive-users@ebi.ac.uk mailing list with questions/suggestions.

=head1 APPENDIX

  The rest of the documentation details each of the object methods.
  Internal methods are preceded with a _

=cut



package Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor;

use strict;
use Bio::EnsEMBL::DBSQL::BaseAdaptor;
use Bio::EnsEMBL::Utils::Argument;
use Bio::EnsEMBL::Utils::Exception;
use Bio::EnsEMBL::Hive::Worker;
use Bio::EnsEMBL::Hive::AnalysisJob;
use Bio::EnsEMBL::Hive::Utils 'stringify';  # import 'stringify()'

use base ('Bio::EnsEMBL::DBSQL::BaseAdaptor');

###############################################################################
#
#  CLASS methods
#
###############################################################################

=head2 CreateNewJob

  Args       : -input_id => string of input_id which will be passed to run the job (or a Perl hash that will be automagically stringified)
               -analysis => Bio::EnsEMBL::Analysis object from a database
               -block        => int(0,1) set blocking state of job (default = 0)
               -input_job_id => (optional) job_id of job that is creating this
                                job.  Used purely for book keeping.
  Example    : $job_id = Bio::EnsEMBL::Hive::DBSQL::AnalysisJobAdaptor->CreateNewJob(
                                    -input_id => 'my input data',
                                    -analysis => $myAnalysis);
  Description: uses the analysis object to get the db connection from the adaptor to store a new
               job in a hive.  This is a class level method since it does not have any state.
               Also updates corresponding analysis_stats by incrementing total_job_count,
               unclaimed_job_count and flagging the incremental update by changing the status
               to 'LOADING' (but only if the analysis is not blocked).
  Returntype : int job_id on database analysis is from.
  Exceptions : thrown if either -input_id or -analysis are not properly defined
  Caller     : general

=cut

sub CreateNewJob {
  my ($class, @args) = @_;

  return undef unless(scalar @args);

  my ($input_id, $analysis, $prev_job, $prev_job_id, $blocked, $semaphore_count, $semaphored_job_id) =
     rearrange([qw(INPUT_ID ANALYSIS PREV_JOB INPUT_JOB_ID BLOCK SEMAPHORE_COUNT SEMAPHORED_JOB_ID)], @args);

  throw("must define input_id") unless($input_id);
  throw("must define analysis") unless($analysis);
  throw("analysis must be [Bio::EnsEMBL::Analysis] not a [$analysis]")
    unless($analysis->isa('Bio::EnsEMBL::Analysis'));
  throw("analysis must have adaptor connected to database")
    unless($analysis->adaptor and $analysis->adaptor->db);
  throw("Please specify prev_job object instead of input_job_id if available") if ($prev_job_id);   # 'obsolete' message

  $prev_job_id = $prev_job && $prev_job->dbID();

        # if the user did not specifically ask for a new fan, consider propagation:
  my $propagate_semaphore = !defined($semaphored_job_id);

        # if nothing is supplied, semaphored_job_id will be propagated from the parent job:
  $semaphored_job_id ||= $prev_job && $prev_job->semaphored_job_id();

  if(ref($input_id)) {  # let's do the Perl hash stringification centrally rather than in many places:
    $input_id = stringify($input_id);
  }

  if(length($input_id) >= 255) {
    my $input_data_id = $analysis->adaptor->db->get_AnalysisDataAdaptor->store_if_needed($input_id);
    $input_id = "_ext_input_analysis_data_id $input_data_id";
  }

  my $dba = $analysis->adaptor->db;
  my $dbc = $dba->dbc;
  my $insertion_method  = ($dbc->driver eq 'sqlite') ? 'INSERT OR IGNORE' : 'INSERT IGNORE';
  my $status            = $blocked ? 'BLOCKED' : 'READY';
  my $analysis_id       = $analysis->dbID();

  my $sql = qq{$insertion_method INTO job 
              (input_id, prev_job_id,analysis_id,status,semaphore_count,semaphored_job_id)
              VALUES (?,?,?,?,?,?)};
 
  my $sth       = $dbc->prepare($sql);
  my @values    = ($input_id, $prev_job_id, $analysis_id, $status, $semaphore_count || 0, $semaphored_job_id);

  my $return_code = $sth->execute(@values)
            # using $return_code in boolean context allows to skip the value '0E0' ('no rows affected') that Perl treats as zero but regards as true:
        or die "Coule not run\n\t$sql\nwith data:\n\t(".join(',', @values).')';

  my $job_id;
  if($return_code > 0) {    # <--- for the same reason we have to be explicitly numeric here:
      $job_id = $dbc->db_handle->last_insert_id(undef, undef, 'job', 'job_id');
      $sth->finish;

      if($semaphored_job_id and $propagate_semaphore) {     # ready to propagate and something to propagate
            $prev_job->adaptor->increase_semaphore_count_for_jobid( $semaphored_job_id ); # propagate the semaphore
      }

      unless($dba->hive_use_triggers()) {
          $dbc->do(qq{
            UPDATE analysis_stats
               SET total_job_count=total_job_count+1
                  ,unclaimed_job_count=unclaimed_job_count+1
                  ,status = (CASE WHEN status!='BLOCKED' THEN 'LOADING' ELSE 'BLOCKED' END)
             WHERE analysis_id=$analysis_id
          });
      }
  } elsif($semaphored_job_id and !$propagate_semaphore) {   # if we didn't succeed in creating the job, fix the semaphore
        $prev_job->adaptor->decrease_semaphore_count_for_jobid( $semaphored_job_id );
  }

  return $job_id;
}

###############################################################################
#
#  INSTANCE methods
#
###############################################################################

=head2 fetch_by_dbID

  Arg [1]    : int $id
               the unique database identifier for the feature to be obtained
  Example    : $feat = $adaptor->fetch_by_dbID(1234);
  Description: Returns the AnalysisJob defined by the job_id $id.
  Returntype : Bio::EnsEMBL::Hive::AnalysisJob
  Exceptions : thrown if $id is not defined
  Caller     : general

=cut

sub fetch_by_dbID {
  my ($self,$id) = @_;

  unless(defined $id) {
    throw("fetch_by_dbID must have an id");
  }

  my @tabs = $self->_tables;

  my ($name, $syn) = @{$tabs[0]};

  #construct a constraint like 't1.table1_id = 1'
  my $constraint = "${syn}.${name}_id = $id";

  #return first element of _generic_fetch list
  my ($obj) = @{$self->_generic_fetch($constraint)};
  return $obj;
}


=head2 fetch_all

  Arg        : None
  Example    : 
  Description: fetches all jobs from database
  Returntype : 
  Exceptions : 
  Caller     : 

=cut

sub fetch_all {
  my $self = shift;

  return $self->_generic_fetch();
}

=head2 fetch_all_failed_jobs

  Arg [1]    : (optional) int $analysis_id
  Example    : $failed_jobs = $adaptor->fetch_all_failed_jobs;
               $failed_jobs = $adaptor->fetch_all_failed_jobs($analysis->dbID);
  Description: Returns a list of all jobs with status 'FAILED'.  If an $analysis_id 
               is specified it will limit the search accordingly.
  Returntype : reference to list of Bio::EnsEMBL::Hive::AnalysisJob objects
  Exceptions : none
  Caller     : user processes

=cut

sub fetch_all_failed_jobs {
  my ($self,$analysis_id) = @_;

  my $constraint = "j.status='FAILED'";
  $constraint .= " AND j.analysis_id=$analysis_id" if($analysis_id);
  return $self->_generic_fetch($constraint);
}


sub fetch_all_incomplete_jobs_by_worker_id {
    my ($self, $worker_id) = @_;

    my $constraint = "j.status IN ('COMPILATION','GET_INPUT','RUN','WRITE_OUTPUT') AND j.worker_id='$worker_id'";
    return $self->_generic_fetch($constraint);
}


sub fetch_by_url_query {
    my ($self, $field_name, $field_value) = @_;

    if($field_name eq 'dbID' and $field_value) {

        return $self->fetch_by_dbID($field_value);

    } else {

        return;

    }
}

#
# INTERNAL METHODS
#
###################

sub _generic_fetch {
  my ($self, $constraint, $join) = @_;
  
  my @tables = $self->_tables;
  my $columns = join(', ', $self->_columns());
  
  if ($join) {
    foreach my $single_join (@{$join}) {
      my ($tablename, $condition, $extra_columns) = @{$single_join};
      if ($tablename && $condition) {
        push @tables, $tablename;
        
        if($constraint) {
          $constraint .= " AND $condition";
        } else {
          $constraint = " $condition";
        }
      } 
      if ($extra_columns) {
        $columns .= ", " . join(', ', @{$extra_columns});
      }
    }
  }
      
  #construct a nice table string like 'table1 t1, table2 t2'
  my $tablenames = join(', ', map({ join(' ', @$_) } @tables));

  my $sql = "SELECT $columns FROM $tablenames";

  my $default_where = $self->_default_where_clause;
  my $final_clause = $self->_final_clause;

  #append a where clause if it was defined
  if($constraint) { 
    $sql .= " WHERE $constraint ";
    if($default_where) {
      $sql .= " AND $default_where ";
    }
  } elsif($default_where) {
    $sql .= " WHERE $default_where ";
  }

  #append additional clauses which may have been defined
  $sql .= " $final_clause";

  my $sth = $self->prepare($sql);
  $sth->execute;  

  #print STDOUT $sql,"\n";

  return $self->_objs_from_sth($sth);
}


sub _tables {
  my $self = shift;

  return (['job', 'j']);
}


sub _columns {
  my $self = shift;

  return qw (j.job_id  
             j.prev_job_id
             j.analysis_id	      
             j.input_id 
             j.worker_id	      
             j.status 
             j.retry_count          
             j.completed
             j.runtime_msec
             j.query_count
             j.semaphore_count
             j.semaphored_job_id
            );
}

sub _default_where_clause {
  my $self = shift;
  return '';
}


sub _final_clause {
  my $self = shift;
  return 'ORDER BY retry_count';
}


sub _objs_from_sth {
  my ($self, $sth) = @_;
  
  my %column;
  $sth->bind_columns( \( @column{ @{$sth->{NAME_lc} } } ));

  my @jobs = ();
    
  while ($sth->fetch()) {

    my $input_id = ($column{'input_id'} =~ /_ext_input_analysis_data_id (\d+)/)
            ? $self->db->get_AnalysisDataAdaptor->fetch_by_dbID($1)
            : $column{'input_id'};

    my $job = Bio::EnsEMBL::Hive::AnalysisJob->new(
        -DBID               => $column{'job_id'},
        -ANALYSIS_ID        => $column{'analysis_id'},
        -INPUT_ID           => $input_id,
        -WORKER_ID          => $column{'worker_id'},
        -STATUS             => $column{'status'},
        -RETRY_COUNT        => $column{'retry_count'},
        -COMPLETED          => $column{'completed'},
        -RUNTIME_MSEC       => $column{'runtime_msec'},
        -QUERY_COUNT        => $column{'query_count'},
        -SEMAPHORE_COUNT    => $column{'query_count'},
        -SEMAPHORED_JOB_ID  => $column{'semaphored_job_id'},
        -ADAPTOR            => $self,
    );

    push @jobs, $job;    
  }
  $sth->finish;
  
  return \@jobs
}


#
# STORE / UPDATE METHODS
#
################

sub decrease_semaphore_count_for_jobid {    # used in semaphore annihilation or unsuccessful creation
    my $self  = shift @_;
    my $jobid = shift @_;
    my $dec   = shift @_ || 1;

    my $sql = "UPDATE job SET semaphore_count=semaphore_count-? WHERE job_id=?";
    
    my $sth = $self->prepare($sql);
    $sth->execute($dec, $jobid);
    $sth->finish;
}

sub increase_semaphore_count_for_jobid {    # used in semaphore propagation
    my $self  = shift @_;
    my $jobid = shift @_;
    my $inc   = shift @_ || 1;

    my $sql = "UPDATE job SET semaphore_count=semaphore_count+? WHERE job_id=?";
    
    my $sth = $self->prepare($sql);
    $sth->execute($inc, $jobid);
    $sth->finish;
}


=head2 update_status

  Arg [1]    : $analysis_id
  Example    :
  Description: updates the job.status in the database
  Returntype : 
  Exceptions :
  Caller     : general

=cut

sub update_status {
    my ($self, $job) = @_;

    my $sql = "UPDATE job SET status='".$job->status."' ";

    if($job->status eq 'DONE') {
        $sql .= ",completed=CURRENT_TIMESTAMP";
        $sql .= ",runtime_msec=".$job->runtime_msec;
        $sql .= ",query_count=".$job->query_count;
    } elsif($job->status eq 'PASSED_ON') {
        $sql .= ", completed=CURRENT_TIMESTAMP";
    } elsif($job->status eq 'READY') {
    }

    $sql .= " WHERE job_id='".$job->dbID."' ";

        # This particular query is infamous for collisions and 'deadlock' situations; let's make them wait and retry.
    foreach (0..3) {
        eval {
            my $sth = $self->prepare($sql);
            $sth->execute();
            $sth->finish;
            1;
        } or do {
            if($@ =~ /Deadlock found when trying to get lock; try restarting transaction/) {    # ignore this particular error
                sleep 1;
                next;
            }
            die $@;     # but definitely report other errors
        };
        last;
    }
    die "After 3 retries still in a deadlock: $@" if($@);
}


=head2 store_out_files

  Arg [1]    : Bio::EnsEMBL::Hive::AnalysisJob $job
  Example    :
  Description: update locations of log files, if present
  Returntype : 
  Exceptions :
  Caller     : Bio::EnsEMBL::Hive::Worker

=cut

sub store_out_files {
    my ($self, $job) = @_;

    if($job->stdout_file or $job->stderr_file) {
        my $insert_sql = 'REPLACE INTO job_file (job_id, retry, worker_id, stdout_file, stderr_file) VALUES (?,?,?,?,?)';
        my $sth = $self->dbc()->prepare($insert_sql);
        $sth->execute($job->dbID(), $job->retry_count(), $job->worker_id(), $job->stdout_file(), $job->stderr_file());
        $sth->finish();
    } else {
        my $sql = 'DELETE from job_file WHERE worker_id='.$job->worker_id.' AND job_id='.$job->dbID;
        $self->dbc->do($sql);
    }
}


=head2 grab_jobs_for_worker

  Arg [1]           : Bio::EnsEMBL::Hive::Worker object $worker
  Example: 
    my $jobs  = $job_adaptor->grab_jobs_for_worker( $worker );
  Description: 
    For the specified worker, it will search available jobs, 
    and using the how_many_this_batch parameter, claim/fetch that
    number of jobs, and then return them.
  Returntype : 
    reference to array of Bio::EnsEMBL::Hive::AnalysisJob objects
  Caller     : Bio::EnsEMBL::Hive::Worker::run

=cut

sub grab_jobs_for_worker {
    my ($self, $worker, $how_many_this_batch) = @_;
  
  my $analysis_id = $worker->analysis->dbID();
  my $worker_id   = $worker->dbID();

  my $update_sql            = "UPDATE job SET worker_id='$worker_id', status='CLAIMED'";
  my $selection_start_sql   = " WHERE analysis_id='$analysis_id' AND status='READY' AND semaphore_count<=0";

  my $virgin_selection_sql  = $selection_start_sql . " AND retry_count=0 LIMIT $how_many_this_batch";
  my $any_selection_sql     = $selection_start_sql . " LIMIT $how_many_this_batch";

  if($self->dbc->driver eq 'sqlite') {
            # we have to be explicitly numereic here because of '0E0' value returned by DBI if "no rows have been affected":
      if( (my $claim_count = $self->dbc->do( $update_sql . " WHERE job_id IN (SELECT job_id FROM job $virgin_selection_sql) AND status='READY'" )) == 0 ) {
            $claim_count = $self->dbc->do( $update_sql . " WHERE job_id IN (SELECT job_id FROM job $any_selection_sql) AND status='READY'" );
      }
  } else {
            # we have to be explicitly numereic here because of '0E0' value returned by DBI if "no rows have been affected":
      if( (my $claim_count = $self->dbc->do( $update_sql . $virgin_selection_sql )) == 0 ) {
            $claim_count = $self->dbc->do( $update_sql . $any_selection_sql );
      }
  }

  my $constraint = "j.analysis_id='$analysis_id' AND j.worker_id='$worker_id' AND j.status='CLAIMED'";
  return $self->_generic_fetch($constraint);
}


sub reclaim_job_for_worker {
    my $self   = shift;
    my $worker = shift or return;
    my $job    = shift or return;

    my $worker_id = $worker->dbID();
    my $job_id    = $job->dbID;

    my $sql = "UPDATE job SET status='CLAIMED', worker_id=? WHERE job_id=? AND status='READY'";

    my $sth = $self->prepare($sql);
    $sth->execute($worker_id, $job_id);
    $sth->finish;

    my $constraint = "j.job_id='$job_id' AND j.worker_id='$worker_id' AND j.status='CLAIMED'";
    return $self->_generic_fetch($constraint);
}


=head2 release_undone_jobs_from_worker

  Arg [1]    : Bio::EnsEMBL::Hive::Worker object
  Arg [2]    : optional message to be recorded in 'job_message' table
  Example    :
  Description: If a worker has died some of its jobs need to be reset back to 'READY'
               so they can be rerun.
               Jobs in state CLAIMED as simply reset back to READY.
               If jobs was in a 'working' state (COMPILATION, GET_INPUT, RUN, WRITE_OUTPUT) 
               the retry_count is increased and the status set back to READY.
               If the retry_count >= $max_retry_count (3 by default) the job is set
               to 'FAILED' and not rerun again.
  Exceptions : $worker must be defined
  Caller     : Bio::EnsEMBL::Hive::Queen

=cut

sub release_undone_jobs_from_worker {
    my ($self, $worker, $msg) = @_;

    my $max_retry_count = $worker->analysis->stats->max_retry_count();
    my $worker_id       = $worker->dbID();

        #first just reset the claimed jobs, these don't need a retry_count index increment:
        # (previous worker_id does not matter, because that worker has never had a chance to run the job)
    $self->dbc->do( qq{
        UPDATE job
           SET status='READY', worker_id=NULL
         WHERE status='CLAIMED'
           AND worker_id='$worker_id'
    } );

    my $sth = $self->prepare( qq{
        SELECT job_id
          FROM job
         WHERE worker_id='$worker_id'
           AND status in ('COMPILATION','GET_INPUT','RUN','WRITE_OUTPUT')
    } );
    $sth->execute();

    my $cod = $worker->cause_of_death();
    $msg ||= "GarbageCollector: The worker died because of $cod";

    my $resource_overusage = ($cod eq 'MEMLIMIT') || ($cod eq 'RUNLIMIT' and $worker->work_done()==0);

    while(my ($job_id) = $sth->fetchrow_array()) {

        my $passed_on = 0;  # the flag indicating that the garbage_collection was attempted and was successful

        if( $resource_overusage ) {
            if($passed_on = $self->gc_dataflow( $worker->analysis->dbID(), $job_id, $cod )) {
                $msg .= ', performing gc_dataflow';
            }
        }
        unless($passed_on) {
            if($passed_on = $self->gc_dataflow( $worker->analysis->dbID(), $job_id, 'ANYFAILURE' )) {
                $msg .= ", performing 'ANYFAILURE' gc_dataflow";
            }
        }

        $self->db()->get_JobMessageAdaptor()->register_message($job_id, $msg, not $passed_on );

        unless($passed_on) {
            $self->release_and_age_job( $job_id, $max_retry_count, not $resource_overusage );
        }
    }
    $sth->finish();
}


sub release_and_age_job {
    my ($self, $job_id, $max_retry_count, $may_retry) = @_;
    $may_retry ||= 0;

        # NB: The order of updated fields IS important. Here we first find out the new status and then increment the retry_count:
        #
        # FIXME: would it be possible to retain worker_id for READY jobs in order to temporarily keep track of the previous (failed) worker?
        #
    $self->dbc->do( qq{
        UPDATE job
           SET status=(CASE WHEN $may_retry AND (retry_count<$max_retry_count) THEN 'READY' ELSE 'FAILED' END), retry_count=retry_count+1
         WHERE job_id=$job_id
           AND status in ('COMPILATION','GET_INPUT','RUN','WRITE_OUTPUT')
    } );
}

=head2 gc_dataflow

    Description:    perform automatic dataflow from a dead job that overused resources if a corresponding dataflow rule was provided
                    Should only be called once during garbage collection phase, when the job is definitely 'abandoned' and not being worked on.

=cut

sub gc_dataflow {
    my ($self, $analysis_id, $job_id, $branch_name) = @_;

    unless(@{ $self->db->get_DataflowRuleAdaptor->fetch_all_by_from_analysis_id_and_branch_code($analysis_id, $branch_name) }) {
        return 0;   # no corresponding gc_dataflow rule has been defined
    }

    my $job = $self->fetch_by_dbID($job_id);

    $job->param_init( 0, $job->input_id() );    # input_id_templates still supported, however to a limited extent

    $job->dataflow_output_id( $job->input_id() , $branch_name );

    $job->update_status('PASSED_ON');

    if(my $semaphored_job_id = $job->semaphored_job_id) {
        $self->decrease_semaphore_count_for_jobid( $semaphored_job_id );    # step-unblock the semaphore
    }
    
    return 1;
}


=head2 reset_job_by_dbID

  Arg [1]    : int $job_id
  Example    :
  Description: Forces a job to be reset to 'READY' so it can be run again.
               Will also reset a previously 'BLOCKED' jobs to READY.
  Exceptions : $job_id must not be false or zero
  Caller     : user process

=cut

sub reset_job_by_dbID {
    my $self   = shift;
    my $job_id = shift or throw("job_id of the job to be reset is undefined");

    $self->dbc->do( qq{
        UPDATE job
           SET status='READY', retry_count=0
         WHERE job_id=$job_id
    } );
}


=head2 reset_all_jobs_for_analysis_id

  Arg [1]    : int $analysis_id
  Example    :
  Description: Resets all not BLOCKED jobs back to READY so they can be rerun.
               Needed if an analysis/process modifies the dataflow rules as the
              system runs.  The jobs that are flowed 'from'  will need to be reset so
              that the output data can be flowed through the new rule.  
              If one is designing a system based on a need to change rules mid-process
              it is best to make sure such 'from' analyses that need to be reset are 'Dummy'
              types so that they can 'hold' the output from the previous step and not require
              the system to actually redo processing.
  Exceptions : $analysis_id must be defined
  Caller     : user RunnableDB subclasses which build dataflow rules on the fly

=cut

sub reset_all_jobs_for_analysis_id {
  my $self        = shift;
  my $analysis_id = shift;

  throw("must define analysis_id") unless($analysis_id);

  my ($sql, $sth);
  $sql = "UPDATE job SET status='READY' WHERE status!='BLOCKED' and analysis_id=?";
  $sth = $self->prepare($sql);
  $sth->execute($analysis_id);
  $sth->finish;

  $self->db->get_AnalysisStatsAdaptor->update_status($analysis_id, 'LOADING');
}

=head2 remove_analysis_id

  Arg [1]    : int $analysis_id
  Example    :
  Description: Remove the analysis from the database.
               Jobs should have been killed before.
  Exceptions : $analysis_id must be defined
  Caller     :

=cut

sub remove_analysis_id {
  my $self        = shift;
  my $analysis_id = shift;

  throw("must define analysis_id") unless($analysis_id);

  my $sql;
  #first just reset the claimed jobs, these don't need a retry_count index increment
  $sql = "DELETE FROM analysis_stats WHERE analysis_id=$analysis_id";
  $self->dbc->do($sql);
  $sql = "ANALYZE TABLE analysis_stats";
  $self->dbc->do($sql);
  $sql = "DELETE FROM job WHERE analysis_id=$analysis_id";
  $self->dbc->do($sql);
  $sql = "ANALYZE TABLE job";
  $self->dbc->do($sql);
  $sql = "DELETE FROM worker WHERE analysis_id=$analysis_id";
  $self->dbc->do($sql);
  $sql = "ANALYZE TABLE worker";
  $self->dbc->do($sql);

}

1;

