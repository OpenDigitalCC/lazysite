package DavDieBeforeRename;
# Loaded into the CHILD lazysite-dav.pl via PERL5OPT by t/unit/dav/33. Makes
# the SM189 raw-HTML guard - a call that sits between the PUT's temp file being
# created and its rename - die, which is how an unexpected engine fault there
# looks. Active only when LAZYSITE_TEST_DIE_IN_PUT is set.
use strict;
use warnings;
BEGIN {
    if ( $ENV{LAZYSITE_TEST_DIE_IN_PUT} ) {
        require Lazysite::Manager::Common;
        no warnings 'redefine';
        *Lazysite::Manager::Common::raw_html_page_refusal
            = sub { die "injected fault between create and rename\n" };
    }
}
1;
