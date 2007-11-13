use strict;
use warnings;
use Test::More tests => 12;
use Test::Exception;
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
	my $qf = Sendmail::Queue::Qf->new({
		queue_directory => 't/tmp',
	});

	ok( $qf->create_and_lock, 'Created a qf file with a unique ID');
	like( $qf->get_queue_id(), qr/^[0-9A-Za-x]{8}[0-9]{6}$/, 'Queue ID looks reasonably sane');
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

	# Override so that our test will work
	no warnings 'redefine';
	local *Sendmail::Queue::Qf::_format_create_time = sub { 'T1234567890' };

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
