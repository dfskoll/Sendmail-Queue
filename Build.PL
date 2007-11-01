use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
    module_name         => 'Sendmail::Queue',
    license             => 'restrictive',
    dist_author         => 'David F. Skoll <dfs@roaringpenguin.com>',
    dist_version_from   => 'lib/Sendmail/Queue.pm',
    build_requires => {
        'Test::More' => 0,
    },
    add_to_cleanup      => [ 'Sendmail-Queue-*' ],
);

$builder->create_build_script();
