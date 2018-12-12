# Test streaming of large transaction with DDL, subtransactions and rollbacks.
use strict;
use warnings;
use PostgresNode;
use TestLib;
use Test::More tests => 2;

sub wait_for_caught_up
{
	my ($node, $appname) = @_;

	$node->poll_query_until('postgres',
"SELECT pg_current_wal_lsn() <= replay_lsn FROM pg_stat_replication WHERE application_name = '$appname';"
	) or die "Timed out while waiting for subscriber to catch up";
}

# Create publisher node
my $node_publisher = get_new_node('publisher');
$node_publisher->init(allows_streaming => 'logical');
$node_publisher->append_conf('postgresql.conf', 'logical_work_mem = 64kB');
$node_publisher->start;

# Create subscriber node
my $node_subscriber = get_new_node('subscriber');
$node_subscriber->init(allows_streaming => 'logical');
$node_subscriber->start;

# Create some preexisting content on publisher
$node_publisher->safe_psql('postgres',
	"CREATE TABLE test_tab (a int primary key, b varchar)");
$node_publisher->safe_psql('postgres',
	"INSERT INTO test_tab VALUES (1, 'foo'), (2, 'bar')");

# Setup structure on subscriber
$node_subscriber->safe_psql('postgres', "CREATE TABLE test_tab (a int primary key, b text, c INT, d text, e INT)");

# Setup logical replication
my $publisher_connstr = $node_publisher->connstr . ' dbname=postgres';
$node_publisher->safe_psql('postgres', "CREATE PUBLICATION tap_pub FOR TABLE test_tab");

my $appname = 'tap_sub';
$node_subscriber->safe_psql('postgres',
"CREATE SUBSCRIPTION tap_sub CONNECTION '$publisher_connstr application_name=$appname' PUBLICATION tap_pub WITH (streaming=true)"
);

wait_for_caught_up($node_publisher, $appname);

# Also wait for initial table sync to finish
my $synced_query =
"SELECT count(1) = 0 FROM pg_subscription_rel WHERE srsubstate NOT IN ('r', 's');";
$node_subscriber->poll_query_until('postgres', $synced_query)
  or die "Timed out while waiting for subscriber to synchronize data";

my $result =
  $node_subscriber->safe_psql('postgres', "SELECT count(*), count(c), count(d) FROM test_tab");
is($result, qq(2|0|0), 'check initial data was copied to subscriber');


# large (streamed) transaction with DDL and DML
$node_publisher->safe_psql('postgres', q{
BEGIN;
SAVEPOINT s1;
INSERT INTO test_tab SELECT i, md5(i::text) FROM generate_series(3, 1000) s(i);
SAVEPOINT s2;
ALTER TABLE test_tab ADD COLUMN c INT;
INSERT INTO test_tab SELECT i, md5(i::text), i FROM generate_series(1001, 2000) s(i);
SAVEPOINT s3;
ALTER TABLE test_tab ADD COLUMN d text;
SAVEPOINT s4;
SAVEPOINT s5;
INSERT INTO test_tab SELECT i, md5(i::text), i, md5(i::text) FROM generate_series(2001, 3000) s(i);
ALTER TABLE test_tab ADD COLUMN e INT;
INSERT INTO test_tab SELECT i, md5(i::text), i, md5(i::text), i FROM generate_series(3001, 4000) s(i);
SAVEPOINT s10;
ALTER TABLE test_tab DROP d;
INSERT INTO test_tab SELECT i, md5(i::text), i, i FROM generate_series(4001, 5000) s(i);
ALTER TABLE test_tab ADD COLUMN d text;
ROLLBACK TO SAVEPOINT s10;
RELEASE SAVEPOINT s10;
SAVEPOINT s10;
INSERT INTO test_tab (a, b, c, d, e) SELECT i, md5(i::text), i, md5(i::text), i FROM generate_series(5001, 6000) s(i);
SAVEPOINT s6;
ALTER TABLE test_tab DROP d;
INSERT INTO test_tab SELECT i, md5(i::text), i, i FROM generate_series(6001, 7000) s(i);
SAVEPOINT s7;
ALTER TABLE test_tab ADD COLUMN d text;
INSERT INTO test_tab (a, b, c, d, e) SELECT i, md5(i::text), i, md5(i::text), i FROM generate_series(7001, 8000) s(i);
COMMIT;
});

wait_for_caught_up($node_publisher, $appname);

$result =
  $node_subscriber->safe_psql('postgres', "SELECT count(*), count(a), count(b), count(c), count(d), count(e) FROM test_tab");
is($result, qq(7000|7000|7000|6000|4000|4000), 'check extra columns contain local defaults');

$node_subscriber->stop;
$node_publisher->stop;
