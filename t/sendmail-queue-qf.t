use strict;
use warnings;
use Test::More tests => 30;
use Test::Exception;
use Test::Deep;
use File::Temp;
use File::Slurp;

BEGIN { 
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
	});

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');
	ok( -r "$dir/qf" . $qf->get_queue_id, 'Queue file exists');
}

# Generation of queue ID after calling set_queue_directory
{
	my $qf = Sendmail::Queue::Qf->new();

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

	my $warn_count = 0;
	{

		local $SIG{__WARN__} = sub { 
			if( $_[0] =~ /exists, incrementing sequence/ ) { 
				$warn_count++;
				return;
			}
			warn $_[0] 
		};
		ok( $qf->create_and_lock, 'Created a qf file with a unique ID');
	}
	is( $warn_count, 3, 'Got 3 warnings about duplicate filename');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');
}


# write()
{
	my $qf = Sendmail::Queue::Qf->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$qf->set_queue_directory( $dir );

	$qf->set_timestamp ( 1234567890 );

	$qf->set_sender('dmo@dmo.ca');
	$qf->add_recipient('dmo@roaringpenguin.com');


	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');
	$qf->set_headers("From: foobar\nTo: someone\nDate: Wed, 07 Nov 2007 14:54:33 -0500\n");

	$qf->write();

	ok( $qf->sync, 'sync() succeeded');

	ok( $qf->close, 'close() succeeded' );

	my $expected = <<'END';
V8
T1234567890
K0
N0
P30000
Fs
$_localhost.localdomain [127.0.0.1]
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

	foreach my $key (qw(timestamp sender helo protocol relay_address relay_hostname local_hostname)) {
		is( $clone->get($key), $qf->get($key), "clone has correct $key");
	}

	cmp_deeply( $clone->get_recipients, [], 'clone has empty recipients');
	is( $clone->get_queue_id, undef, 'clone has no queue id');
	is( $clone->get_queue_fh, undef, 'clone has no queue fh');
}
