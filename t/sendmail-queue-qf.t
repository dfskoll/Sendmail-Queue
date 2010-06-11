package test_queue_df;
use strict;
use warnings;

use base qw( Test::Class );

use Test::Most;
use File::Temp;
use File::Slurp;


# fake rand() to always return 0 for testing purposes.
# Because rand() is a builtin, it's hard to clobber...
BEGIN {
	*Sendmail::Queue::Qf::rand = sub { 0 };
	eval 'require Sendmail::Queue::Qf' or die $@;
};

sub make_tmpdir : Test(setup)
{
	my ($self) = @_;
	$self->{tmpdir} = File::Temp::tempdir( CLEANUP => 1 );
}

sub del_tmpdir : Test(teardown)
{
	my ($self) = @_;

	delete $self->{tmpdir};
}

sub test_constructor : Test(1)
{
	my $qf = Sendmail::Queue::Qf->new();
	isa_ok( $qf, 'Sendmail::Queue::Qf');
}

sub set_queue_id_manually : Test(1)
{
	my $qf = Sendmail::Queue::Qf->new();
	$qf->set_queue_id( 'wookie' );
	is( $qf->get_queue_id(), 'wookie', 'Got the queue ID we set');
}

sub generate_queue_id : Test(3)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		queue_directory => $self->{tmpdir},
		timestamp => 1234567890,
	});

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	my $pid = sprintf("%06d", $$);
	is( $qf->get_queue_id(), "n1DNVU00$pid", 'Queue ID is correct and has sequence number of 0');
	ok( -r "$self->{tmpdir}/qf" . $qf->get_queue_id, 'Queue file exists');
}

sub generate_qf_file : Test(2)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		timestamp       => 1234567890,
		queue_directory => $self->{tmpdir},
	});

	# All of this evil is to force file collisions so that we can see that
	# the sequence number is 3 higher than the value given by rand().
	my $count = 0;
	my $existing_file = "$self->{tmpdir}/foo";
	open(FH,">$existing_file") or die $!;
	close FH;
	no warnings 'once';
	local *File::Spec::catfile = sub {
		my $class = shift;
		if( $count++ < 3 ) {
			note("Forcing collision for $_[1]");
			return $existing_file;
		}
		return join('/', @_);
	};

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');

	my $pid = sprintf("%06d", $$);
	is( $qf->get_queue_id(), "n1DNVU03$pid", 'Queue ID is correct and has sequence number of 3');
}


sub write_qf : Test(4)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		timestamp       => 1234567890,
		queue_directory => $self->{tmpdir},
		protocol    => 'ESMTP',
		sender      => 'dmo@dmo.ca',
		recipients  => [ 'dmo@roaringpenguin.com' ],
	});

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

sub generate_received : Test(3)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		timestamp       => 1195000000,
		queue_directory => $self->{tmpdir},
	});

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

sub clone_qf_file : Test(9)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		timestamp       => 1195000000,
		queue_directory => $self->{tmpdir},
	});

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

	my %expected = %{$qf};
	delete $expected{$_} for qw(queue_id sender queue_fh received_header);
	$expected{recipients} = [];
	cmp_deeply(
		$clone,
		noclass(\%expected),
		'Clone has correct data');

	is( $clone->get_sender, undef, 'clone has no sender');
	cmp_deeply( $clone->get_recipients, [], 'clone has empty recipients');
	is( $clone->get_queue_id, undef, 'clone has no queue id');
	is( $clone->get_queue_fh, undef, 'clone has no queue fh');
}

sub unlink_qf_file : Test(9)
{
	my ($self) = @_;

	my $qf = Sendmail::Queue::Qf->new({
		timestamp       => 1195000000,
		queue_directory => $self->{tmpdir},
	});

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

__PACKAGE__->runtests unless caller();
