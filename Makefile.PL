use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Sendmail::Queue',
    AUTHOR              => 'David F. Skoll <dfs@roaringpenguin.com>',
    VERSION_FROM        => 'lib/Sendmail/Queue.pm',
    ABSTRACT_FROM       => 'lib/Sendmail/Queue.pm',
    PL_FILES            => {},
    PREREQ_PM => {
        'Test::More' => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Sendmail-Queue-*' },
);
