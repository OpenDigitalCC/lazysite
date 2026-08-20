#!/usr/bin/perl
# SM422: the submission read gate followed the PATH, not the store.
#
# The control API's form-submissions route resolves through
# _submission_store_dirs - the default store plus each file-handler's
# configured `path` (the SM268 H1 allowlist). The carve-out gate that governs
# MCP read_file and the cookie file surface keyed on the fixed prefix
# 'lazysite/forms/submissions/' instead. The two agree for a default install
# and diverge the moment an operator configures a store elsewhere, which the
# allowlist explicitly permits:
#
#   read_file /lazysite/forms/submissions/contact.jsonl  => refused
#   read_file /content/leads/data.jsonl                  => SERVED
#
# Same kind of data, two guards, and the read gate depending on which surface
# reached it. Reported by the security-review agent's round-3 triage,
# reproduced there against the real MCP process.
#
# Driven through carveout_refusal directly - that is the gate both the MCP
# dispatcher and the API file surface consult, so it is where the property
# lives.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Common  ();
use Lazysite::Manager::Plugins ();

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/forms", "$d/content/leads" );
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Manager::Plugins::DOCROOT = $d;

# A file handler storing OUTSIDE lazysite/forms - a supported configuration,
# and the one the two guards disagreed about.
open my $h, '>', "$d/lazysite/forms/handlers.conf" or die $!;
print {$h} <<'CONF';
handlers:
  - id: leads
    type: file
    path: content/leads
CONF
close $h;

sub refusal {
    my ( $path, $caps ) = @_;
    return Lazysite::Manager::Common::carveout_refusal( $path, 'read', $caps );
}

my $EDITOR = { manage_content => 1 };
my $READER = { manage_content => 1, read_submissions => 1 };

subtest 'the fixture really registers the outside store' => sub {
    my @dirs = Lazysite::Manager::Plugins::submission_store_dirs();
    ok( ( grep { $_ eq 'content/leads' } @dirs ),
        'content/leads is a configured store' )
        or diag( "dirs: " . join( ', ', @dirs ) );
};

subtest 'the DEFAULT store is gated, as it always was' => sub {
    ok( refusal( 'lazysite/forms/submissions/contact.jsonl', $EDITOR ),
        'a manage_content editor is refused' );
    ok( !refusal( 'lazysite/forms/submissions/contact.jsonl', $READER ),
        'and read_submissions reaches it' );
};

subtest 'a CONFIGURED store outside lazysite/forms is gated the same way' => sub {
    ok( refusal( 'content/leads/data.jsonl', $EDITOR ),
        'the editor is refused there too - this is the divergence closed' )
        or diag( 'The gate keyed on the fixed prefix, so a store configured '
            . 'elsewhere had no read gate on this surface at all.' );
    ok( !refusal( 'content/leads/data.jsonl', $READER ),
        'and read_submissions reaches it, so the fix gates rather than bans' );
};

subtest 'ordinary content is untouched' => sub {
    # The control that matters: a gate keyed on "any configured path" that
    # caught the whole content tree would be a far worse defect than the one
    # being fixed, and every assertion above would still pass.
    ok( !refusal( 'content/page.md',         $EDITOR ), 'a page is readable' );
    ok( !refusal( 'content/leads-report.md', $EDITOR ),
        'and so is a path that merely RESEMBLES the store prefix' );
    ok( !refusal( 'index.md', $EDITOR ), 'and the homepage' );
};

done_testing();
