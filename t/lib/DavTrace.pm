package DavTrace;
# Loaded into lazysite-dav.pl via PERL5OPT by t/integration/262. Appends one
# line when the script starts and one when it ends, with the .tmp.<pid> names
# in the content directory at that moment, so the test can say whether the
# engine ran at all and whether it ended by exit (an END block ran) or was
# killed (no end line). Active only when LAZYSITE_TEST_TRACE names a file.
use strict;
use warnings;

sub _note {
    my ($what) = @_;
    my $f = $ENV{LAZYSITE_TEST_TRACE} or return;
    my @t;
    if ( my $d = $ENV{LAZYSITE_TEST_TRACE_DIR} ) {
        if ( opendir my $dh, $d ) { @t = grep { /\.tmp\.\d+\z/ } readdir $dh; closedir $dh }
    }
    open my $fh, '>>', $f or return;
    print {$fh} "$what pid=$$ tmps=" . join( ',', @t ) . "\n";
    close $fh;
    return;
}

BEGIN { _note('begin') }
END   { local $?; _note('end') }
1;
