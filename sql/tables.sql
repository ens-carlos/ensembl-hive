------------------------------------------------------------------------------------
--
-- Table structure for table 'hive'
--
-- overview:
--   Table which tracks the workers of a hive as they exist out in the world.
--   Workers are created by inserting into this table so that there is only every
--   one instance of a worker object in the world.  As workers live and do work,
--   they update this table, and when they die they update.
--
-- semantics:
--

CREATE TABLE hive (
  hive_id          int(10) NOT NULL auto_increment,
  analysis_id      int(10) NOT NULL,
  beekeeper        varchar(80) DEFAULT '' NOT NULL,
  host	           varchar(40) DEFAULT '' NOT NULL,
  process_id       varchar(40) DEFAULT '' NOT NULL,
  work_done        int(11) DEFAULT '0' NOT NULL,
  born	           datetime NOT NULL,
  last_check_in    datetime NOT NULL,
  died             datetime DEFAULT NULL,
  cause_of_death   enum('', 'NO_WORK', 'JOB_LIMIT', 'LIFESPAN', 'FATALITY') DEFAULT '' NOT NULL,
  PRIMARY KEY (hive_id)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'simple_rule'
--
-- overview:
--   redesign of pipeline rule system.  Basic design is simplifed so that a
--   'rule' is simply a link from one analysis object to another
--     (ie an edge in a flowchart or object interaction diagram where
--      condition_analysis_id => goal_analysis_id)
--   Each analysis object (analysis_id) is a unique node in the
--   graph that describes the pipeline system.
--     (ie each analysis_id is an 'Instance' of the module it points to)
--   Main reason for redesign that by making a single table we can implement
--   a UNIQUE constraint so that the pipeline can modify itself as it runs
--   and avoid race conditions where the same link is created multiple times
--
-- semantics:
--   simple_rule_id           - internal ID
--   condition_analysis_id    - foreign key to analysis table analysis_id
--   goal_analysis_id         - foreign key to analysis table analysis_id
--   branch_code              - joined to analysis_job.branch_code to allow branching

CREATE TABLE simple_rule (
  simple_rule_id           int(10) unsigned not null auto_increment,
  condition_analysis_id    int(10) unsigned NOT NULL,
  goal_analysis_id         int(10) unsigned NOT NULL,
  branch_code              int(10) default 1 NOT NULL,

  PRIMARY KEY (simple_rule_id),
  UNIQUE (condition_analysis_id, goal_analysis_id)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'dataflow_rule'
--
-- overview:
--   Extension of simple_rule design except that goal(to) is now in extended URL format e.g.
--   mysql://ensadmin:<pass>@ecs2:3361/compara_hive_test?analysis.logic_name='blast_NCBI34'
--   (full network address of an analysis).  The only requirement is that there are rows in 
--   the analysis_job, analysis, dataflow_rule, and hive tables so that the following join
--   works on the same database 
--   WHERE analysis.analysis_id = dataflow_rule.from_analysis_id 
--   AND   analysis.analysis_id = analysis_job.analysis_id
--   AND   analysis.analysis_id = hive.analysis_id
--
--   These are the rules used to create entries in the analysis_job table where the
--   input_id (control data) is passed from one analysis to the next to define work.
--  
--   The analysis table will be extended so that it can specify different read and write
--   databases, with the default being the database the analysis is on
--
-- semantics:
--   dataflow_rule_id     - internal ID
--   from_analysis_id     - foreign key to analysis table analysis_id
--   to_analysis_url      - foreign key to net distributed analysis logic_name reference
--   branch_code          - joined to analysis_job.branch_code to allow branching

CREATE TABLE dataflow_rule (
  dataflow_rule_id    int(10) unsigned not null auto_increment,
  from_analysis_id    int(10) unsigned NOT NULL,
  to_analysis_url     varchar(255) default '' NOT NULL,
  branch_code         int(10) default 1 NOT NULL,

  PRIMARY KEY (dataflow_rule_id),
  UNIQUE (from_analysis_id, to_analysis_url)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'analysis_ctrl_rule'
--
-- overview:
--   These rules define a higher level of control.  These rules are used to turn
--   whole anlysis nodes on/off (READY/BLOCKED).
--   If any of the condition_analyses are not 'DONE' the ctrled_analysis is set BLOCKED
--   When all conditions become 'DONE' then ctrled_analysis is set to READY
--   The workers switch the analysis.status to 'WORKING' and 'DONE'.
--   But any moment if a condition goes false, the analysis is reset to BLOCKED.
--
--   This process of watching conditions and flipping the ctrled_analysis state
--   will be accomplished by another automous agent (CtrlWatcher.pm)
--
-- semantics:
--   condition_analysis_url  - foreign key to net distributed analysis reference
--   ctrled_analysis_id      - foreign key to analysis table analysis_id

CREATE TABLE analysis_ctrl_rule (
  condition_analysis_url     varchar(255) default '' NOT NULL,
  ctrled_analysis_id         int(10) unsigned NOT NULL,

  UNIQUE (condition_analysis_url, ctrled_analysis_id)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'analysis_job'
--
-- overview:
--   The analysis_job is the heart of this sytem.  It is the kiosk or blackboard
--   where workers find things to do and then post work for other works to do.
--   The job_claim is a UUID set with an UPDATE LIMIT by worker as they fight
--   over the work.  These jobs are created prior to work being done, are claimed
--   by workers, are updated as the work is done, with a final update on completion.
--
-- semantics:
--   analysis_job_id        - autoincrement id
--   input_analysis_job_id  - previous analysis_job which created this one (and passed input_id)
--   analysis_id            - the analysis_id needed to accomplish this job.
--   input_id               - input data passed into Analysis:RunnableDB to control the work
--   job_claim              - UUID set by workers as the fight over jobs
--   hive_id                - link to hive table to define which worker claimed this job
--   status                 - state the job is in
--   retry_count            - number times job had to be reset when worker failed to run it
--   completed              - timestamp when job was completed
--   branch_code            - switch-like branching control, default=1 (ie true)

CREATE TABLE analysis_job (
  analysis_job_id        int(10) NOT NULL auto_increment,
  input_analysis_job_id  int(10) NOT NULL,  #analysis_job which created this from rules
  analysis_id            int(10) NOT NULL,
  input_id               varchar(100) not null,
  job_claim              varchar(40) NOT NULL default '', #UUID
  hive_id                int(10) NOT NULL,
  status                 enum('READY','BLOCKED','CLAIMED','GET_INPUT','RUN','WRITE_OUTPUT','DONE','FAILED') DEFAULT 'READY' NOT NULL,
  retry_count            int(10) default 0 not NULL,
  completed              datetime NOT NULL,
  branch_code            int(10) default 1 NOT NULL,

  PRIMARY KEY                  (analysis_job_id),
  UNIQUE KEY input_id_analysis (input_id, analysis_id),
  INDEX job_claim_analysis     (job_claim, analysis_id),
  INDEX job_analysis_status    (analysis_id, status),
  INDEX hive_id                (hive_id)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'analysis_job_file'
--
-- overview:
--   Table which holds paths to files created by an analysis_job
--   e.g. STDOUT STDERR, temp directory
--   or output data files created by the RunnableDB
--   There can only be one entry of a certain type for a given analysis_job
--
-- semantics:
--   analysis_job_id    - foreign key
--   type               - type of file e.g. STDOUT, STDERR, TMPDIR, ...
--   path               - path to file or directory

CREATE TABLE analysis_job_file (
  analysis_job_id         int(10) NOT NULL,
  type                    varchar(16) NOT NULL default '',
  path                    varchar(255) NOT NULL,
  
  UNIQUE KEY   (analysis_job_id, type)
);


------------------------------------------------------------------------------------
--
-- Table structure for table 'analysis_stats'
--
-- overview:
--   Parallel table to analysis which provides high level statistics on the
--   state of an analysis and it's jobs.  Used to provide a fast overview, and to
--   provide final approval of 'DONE' which is used by the blocking rules to determine
--   when to unblock other analyses.  Also provides
--
-- semantics:
--   analysis_id    - foreign key to analysis table
--   status         - overview status of the analysis_jobs (cached state)

CREATE TABLE analysis_stats (
  analysis_id           int(10) NOT NULL,
  status                enum('BLOCKED', 'READY', 'WORKING', 'ALL_CLAIMED', 'DONE')
                          DEFAULT 'READY' NOT NULL,
  batch_size            int(10) default 1 NOT NULL,
  hive_capacity         int(10) default 1 NOT NULL,
  total_job_count       int(10) NOT NULL,
  unclaimed_job_count   int(10) NOT NULL,
  done_job_count        int(10) NOT NULL,
  failed_job_count      int(10) NOT NULL,
  num_required_workers  int(10) NOT NULL,
  last_update           timestamp NOT NULL,
  
  UNIQUE KEY   (analysis_id)
);


