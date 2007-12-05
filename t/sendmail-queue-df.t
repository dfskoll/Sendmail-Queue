use strict;
use warnings;
use Test::More tests => 13;
use Test::Exception;
use File::Temp;
use File::Slurp;

BEGIN { 
	use_ok('Sendmail::Queue::Df'); 
}

# Constructor
{
	my $df = Sendmail::Queue::Df->new();
	isa_ok( $df, 'Sendmail::Queue::Df');
}

# Setting of queue ID manually
{
	my $df = Sendmail::Queue::Df->new();
	$df->set_queue_id( 'wookie' );
	is( $df->get_queue_id(), 'wookie', 'Got the queue ID we set');
}

# write()
{
	my $df = Sendmail::Queue::Df->new();
	$df->set_queue_id( 'wookie' );

	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$df->set_queue_directory( $dir );

	my $expected = <<'END';
This is the message body

-- 
Dave
END

	$df->set_data( $expected );
	$df->write();

	is( File::Slurp::slurp( $df->get_data_filename ), $expected, 'Wrote expected data');
}

# hardlink_to()
{
	my $df = Sendmail::Queue::Df->new();
	$df->set_queue_id( 'DoubleWookie' );

	my $dir = File::Temp::tempdir( CLEANUP => 1 );

	$df->set_queue_directory( $dir );

	my $expected = <<'END';
This is another message body

-- 
Dave
END

	my $file = $df->get_queue_directory() . "/testfile";

	open(FH, ">$file") or die $!;
	print FH $expected or die $!;
	close FH or die $!;

	$df->hardlink_to( $file );

	# TODO: stat both files and check the inode

	$df->write();

	is( File::Slurp::slurp( $df->get_data_filename ), $expected, 'Linked to expected data');

	unlink $file or die $!;

	is( File::Slurp::slurp( $df->get_data_filename ), $expected, 'Unlinking original causes no problems');


}

# unlink
{
	my $df = Sendmail::Queue::Df->new();
	my $dir = File::Temp::tempdir( CLEANUP => 1 );
	$df->set_queue_directory( $dir );

	ok( ! $df->get_data_filename, 'Object has no filename');
	ok( ! $df->unlink, 'Unlink fails when no filename');

	$df->set_data('foo');
	$df->set_queue_id( 'chewbacca' );
	ok( $df->write, 'Created a file');
	ok( -e $df->get_data_filename, 'File exists');
	ok( $df->unlink, 'Unlink succeeds when file exists');
	ok( ! -e $df->get_data_filename, 'File now deleted');

	ok( ! $df->unlink, 'Unlink fails because file now does not exist');
}
