#!/usr/bin/perl
# SM976 Q15h (ruled 2026-10-09, "Pin with a test"): A .url PAGE BINDS NO FORM.
#
# process_url parses the fetched page's front matter but never converts a
# :::form block, so a .url page whose remote text says `form: leads` renders
# no form and writes no form rules (tmp/q15g-url-form-probe.out). The form
# rule's walker (Manager::Common::form_bindings) reads only local .md pages,
# and never fetches - which is right only while this holds. If .url pages ever
# render forms (convert_fenced_form in process_url, for parity with process_md),
# a remote page could bind any form without any walker seeing it: a form is
# reached through the pages that bind it (SM976 F2).
#
# No network: Lazysite::Fetch::fetch_url is replaced in process, as
# t/unit/manager/210 stubs it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir);

my $d = site_tempdir();
setup_minimal_site($d);
make_path("$d/lazysite/forms");
sub spit { open my $fh, '>', $_[0] or die "$_[0]: $!"; print {$fh} $_[1]; close $fh; return }

spit( "$d/lazysite/forms/leads.conf", "targets:\n" );
spit( "$d/remote.url",                "https://example.com/hook\n" );
my $REMOTE = "---\ntitle: Remote\nform: leads\n---\n\nRemote text.\n\n:::form\nnote | Note | max:5\n:::\n";

load_processor($d);
require Lazysite::Fetch;
{
    no warnings qw(redefine once);
    *Lazysite::Fetch::fetch_url = sub { $REMOTE };
}

my $WHY = 'a .url page now renders a form or writes form rules. Before this is allowed, '
    . 'form_bindings (Lazysite::Manager::Common, the form rule\'s walker) must account for .url '
    . 'pages - fetch them, or count every .url page as binding the forms its remote text names - '
    . 'or a remote page binds a form no walker sees (SM976 F2, Q15h)';

my $html = main::process_url( "$d/remote.url", "$d/remote.html", ( stat "$d/remote.url" )[9] );
$html = $html->[0] if ref $html eq 'ARRAY';
like( $html, qr/Remote text\./, 'the fetched page renders (the rig reaches process_url)' );
my ($meta) = main::parse_yaml_front_matter($REMOTE);
is( $meta->{form}, 'leads', 'and its front matter names a form' );
unlike( $html, qr/name="_form"/i, 'a .url page renders no form' )     or diag($WHY);
ok( !-e "$d/lazysite/forms/leads.rules", 'and writes no form rules' ) or diag($WHY);

# The control: the same text as a local .md page renders the form and writes
# its rules, so the assertions above can fail.
spit( "$d/local.md", $REMOTE );
my $lh = main::process_md( "$d/local.md", "$d/local.html", ( stat "$d/local.md" )[9], {} );
$lh = $lh->[0] if ref $lh eq 'ARRAY';
like( $lh, qr/name="_form"/i, 'control: the same text as a .md page renders the form' );
ok( -e "$d/lazysite/forms/leads.rules", 'control: and writes its rules' );

done_testing();
