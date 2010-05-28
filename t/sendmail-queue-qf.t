use strict;
use warnings;
use Test::More tests => 38;
use Test::Exception;
use Test::Deep;
use File::Temp;
use File::Slurp;

BEGIN {

	# fake rand() to always return 0 for testing purposes.
	# Because rand() is a builtin, it needs to be overridden at
	# BEGIN time, before Sendmail::Queue::Qf is read in.
	*Sendmail::Queue::Qf::rand = sub {
		0;
	};

	use_ok('Sendmail::Queue::Qf');
}

# Constructor
{
	my $qf = Sendmail::Queue::Qf->new();
	isa_ok( $qf, 'Sendmail::Queue::Qf');
}

# Setting of queue ID manually
{
	my $qf = Sendmail::Queue::Qf->new();
	$qf->set_queue_id( 'wookie' );
	is( $qf->get_queue_id(), 'wookie', 'Got the queue ID we set');
}

# Generation of queue ID
{
	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	my $qf = Sendmail::Queue::Qf->new({
		queue_directory => $dir,
		timestamp => 1234567890,
	});

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	my $pid = sprintf("%06d", $$);
	is( $qf->get_queue_id(), "n1DNVU00$pid", 'Queue ID is correct and has sequence number of 0');
	ok( -r "$dir/qf" . $qf->get_queue_id, 'Queue file exists');
}

# Generation of queue ID after calling set_queue_directory
{
	my $qf = Sendmail::Queue::Qf->new({
		timestamp => 1234567890,
	});

	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$qf->set_queue_directory( $dir );

	my $count = 0;
	my $existing_file = "$dir/foo";
	open(FH,">$existing_file") or die $!;
	close FH;
	no warnings 'once';
	local *File::Spec::catfile = sub {

		if( $count++ < 3 ) {
			return $existing_file;
		}
		return "$dir/new_file";
	};

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	my $pid = sprintf("%06d", $$);
	is( $qf->get_queue_id(), "n1DNVU03$pid", 'Queue ID is correct and has sequence number of 3');
}


# write()
{
	my $qf = Sendmail::Queue::Qf->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$qf->set_queue_directory( $dir );

	$qf->set_timestamp ( 1234567890 );
	$qf->set_protocol('ESMTP');
	$qf->set_sender('dmo@dmo.ca');
	$qf->add_recipient('dmo@roaringpenguin.com');


	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');
	$qf->set_headers("From: foobar\nTo: someone\nDate: Wed, 07 Nov 2007 14:54:33 -0500\n");

	$qf->write();

	ok( $qf->sync, 'sync() succeeded');

	ok( $qf->close, 'close() succeeded' );

	my $expected = <<'END';
V6
T1234567890
K0
N0
P30000
F
$rESMTP
${daemon_flags}
S<dmo@dmo.ca>
C:<dmo@roaringpenguin.com>
rRFC822; dmo@roaringpenguin.com
RPFD:dmo@roaringpenguin.com
H??From: foobar
H??To: someone
H??Date: Wed, 07 Nov 2007 14:54:33 -0500
.
END

	is( File::Slurp::slurp( $qf->get_queue_filename ), $expected, 'Wrote expected data');

}

# synthesize_received_header
{
	my $qf = Sendmail::Queue::Qf->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$qf->set_queue_directory( $dir );
	$qf->set_timestamp(1195000000);
	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	# First, try it with no values set.
	$qf->synthesize_received_header();
	my $r_hdr = qr/^Received: \(from dmo\@localhost\)\n\tby localhost \(Sendmail::Queue\) id lAE0Qe..\d{6}; Tue, 13 Nov 2007 19:26:40 -0500$/;
	like( $qf->get_received_header(), $r_hdr, 'Got expected Received header');

	# Wipe and try again
	$qf->set_headers('');

	$qf->set_sender('dmo@dmo.ca');
	$qf->set_helo('loser');
	$qf->set_protocol('ESMTP');
	$qf->set_relay_address('999.888.777.666');
	$qf->set_relay_hostname('broken.dynamic.server.example.com');
	$qf->set_local_hostname('mail.roaringpenguin.com');
	$qf->add_recipient('dmo@roaringpenguin.com');


	$qf->synthesize_received_header();
	$r_hdr = qr/^Received: from loser \Q(broken.dynamic.server.example.com [999.888.777.666])
	by mail.roaringpenguin.com (envelope-sender dmo\E\@dmo.ca\Q) (Sendmail::Queue)\E with ESMTP id lAE0Qe..\d{6}\n\tfor dmo\@roaringpenguin\.com; Tue, 13 Nov 2007 19:26:40 -0500$/;

	like( $qf->get_received_header(), $r_hdr, 'Got expected Received header');
}

# clone
{
	my $qf = Sendmail::Queue::Qf->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );
	$qf->set_queue_directory( $dir );
	$qf->set_timestamp(1195000000);
	$qf->set_sender('dmo@dmo.ca');
	$qf->set_helo('loser');
	$qf->set_protocol('ESMTP');
	$qf->set_relay_address('999.888.777.666');
	$qf->set_relay_hostname('broken.dynamic.server.example.com');
	$qf->set_local_hostname('mail.roaringpenguin.com');
	$qf->add_recipient('dmo@roaringpenguin.com');
	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	$qf->synthesize_received_header();
	my $r_hdr = qr/^Received: from loser \Q(broken.dynamic.server.example.com [999.888.777.666])
	by mail.roaringpenguin.com (envelope-sender dmo\E\@dmo.ca\Q) (Sendmail::Queue)\E with ESMTP id lAE0Qe..\d{6}\n\tfor dmo\@roaringpenguin\.com; Tue, 13 Nov 2007 19:26:40 -0500$/;

	like( $qf->get_received_header(), $r_hdr, 'Got expected Received header');

	my $clone;
	lives_ok { $clone = $qf->clone() } 'clone() lives';
	isa_ok($clone, 'Sendmail::Queue::Qf');

	foreach my $key (qw(timestamp helo protocol relay_address relay_hostname local_hostname)) {
		is( $clone->get($key), $qf->get($key), "clone has correct $key");
	}

	is( $clone->get_sender, undef, 'clone has no sender');
	cmp_deeply( $clone->get_recipients, [], 'clone has empty recipients');
	is( $clone->get_queue_id, undef, 'clone has no queue id');
	is( $clone->get_queue_fh, undef, 'clone has no queue fh');
}

# unlink
{
	my $qf = Sendmail::Queue::Qf->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );
	$qf->set_queue_directory( $dir );

	ok( ! $qf->get_queue_filename, 'Object has no filename');
	ok( ! $qf->unlink, 'Unlink fails when no filename');

	ok( $qf->create_and_lock, 'Created a file');
	ok( -e $qf->get_queue_filename, 'File exists');
	ok( $qf->unlink, 'Unlink succeeds when file exists');
	ok( ! -e $qf->get_queue_filename, 'File now deleted');

	ok( ! $qf->unlink, 'Unlink fails because file now does not exist');

	dies_ok { $qf->write() } 'Write dies because queue file closed and deleted';
	like($@, qr/write\(\) cannot write without an open filehandle/, '... with expected error');
}
