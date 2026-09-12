#!/usr/bin/perl
# SM862: reading submissions says which parameter is missing, and takes the form
# name the rest of the system uses.
#
# `form-submissions` takes `file` - a relative path ending .jsonl, inside a
# configured store. Called with `form=<name>` and no `file`, _submissions_path
# received undef, failed the .jsonl test, and answered "Invalid submissions
# file" with 400: a MISSING parameter described as a BAD VALUE.
#
# The site agent lost time to exactly that and wrote it down:
#
#   "Called as form-submissions&form=1313e-esc it answers {"ok":false,
#    "error":"Invalid submissions file"} with 400, for a form whose store
#    form-list reports as present with one row. I nearly filed that as a broken
#    action. It is the fourth time in this campaign that a missing or misnamed
#    parameter is reported as an invalid value."
#
# TWO THINGS ARE WRONG THERE, and fixing only the message would leave the worse
# one. MCP's read_form_submissions takes a form NAME and resolves the store
# (SM855); `form-targets-read` on this very channel takes `form`. So the control
# API was the odd surface, and `form=` was the reasonable thing to send. It now
# resolves through the same resolver MCP uses, so the two channels cannot
# disagree about where a form's submissions live.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper                 qw(site_tempdir);
use Lazysite::Manager::Plugins ();
use Lazysite::Handlers         ();

my $docroot = site_tempdir();
my $lz      = "$docroot/lazysite";
make_path("$lz/forms/submissions");
make_path("$lz/forms");
open my $cf, '>', "$lz/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;

# A form whose store is the default one, with a submission in it.
open my $ff, '>', "$lz/forms/enquiry.conf" or die $!;
print {$ff} "targets:\n  - handler: to-file\n";
close $ff;
open my $sf, '>', "$lz/forms/submissions/enquiry.jsonl" or die $!;
print {$sf} qq({"name":"A Visitor","note":"hello"}\n);
close $sf;

$Lazysite::Manager::Plugins::DOCROOT      = $docroot;
$Lazysite::Handlers::DOCROOT              = $docroot;
$Lazysite::Manager::Plugins::LAZYSITE_DIR = $lz;
$Lazysite::Handlers::LAZYSITE_DIR         = $lz;

subtest 'neither parameter: the refusal names them, and does not call it invalid' => sub {
    my $r = Lazysite::Manager::Plugins::action_form_submissions( undef, undef );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error}, qr/\bfile\b/, 'names `file`' );
    like( $r->{error}, qr/\bform\b/, 'and names `form`' );
    unlike( $r->{error}, qr/Invalid/i,
        'and does NOT describe an absent parameter as an invalid value' )
        or diag( 'This is the fourth time in one campaign that a missing '
            . 'parameter was reported as a bad one. A caller who sent nothing '
            . 'is told their value is wrong, and goes looking at the value.' );
    is( $r->{kind}, 'missing-parameter', 'and says so by kind' );
};

subtest 'a form name resolves to that form\'s own store' => sub {
    my $r = Lazysite::Manager::Plugins::action_form_submissions( undef, 'enquiry' );
    ok( $r->{ok}, 'the read succeeds on a form name alone' ) or diag( explain $r );
    is( $r->{total}, 1, 'and returns the submission' );
    like( $r->{file}, qr/enquiry\.jsonl\z/, 'reporting the file it resolved to' );
};

subtest 'file still works, and wins when both are sent' => sub {
    my $r = Lazysite::Manager::Plugins::action_form_submissions(
        'lazysite/forms/submissions/enquiry.jsonl', undef );
    ok( $r->{ok}, 'an explicit path still reads' ) or diag( explain $r );
    is( $r->{total}, 1, 'and returns the submission' );
};

subtest 'an unknown form is not-found, not invalid' => sub {
    # The store for a form that does not exist resolves to the DEFAULT
    # directory, so the path is legitimate and simply absent - which is the
    # empty answer, not a refusal. What must not happen is the path being
    # reported as malformed.
    my $r = Lazysite::Manager::Plugins::action_form_submissions( undef, 'no-such-form' );
    ok( $r->{ok}, 'an absent store reads as empty rather than refusing' )
        or diag( explain $r );
    is( $r->{total}, 0, 'with no rows' );
};

done_testing();
