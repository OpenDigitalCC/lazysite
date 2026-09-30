#!/usr/bin/perl
# SM926 and SM928 defect 1, which land together because the link is built from the
# variable the other one flattens.
#
# SM926: `site_url` holds `${REQUEST_SCHEME}://${SERVER_NAME}` on every site
# install.pl or TestHelper creates. Notify returned it RAW, so the first XMPP
# notification to arrive on a live site carried
# `${REQUEST_SCHEME}://${SERVER_NAME}/manager/plugins` as its link. Two other
# readers in the tree expanded it; this was the third and the only one that did not.
#
# SM928 defect 1: the newline strip before the notices.jsonl append also fed %vars,
# so a multi-line body was flattened for every endpoint and template - and only the
# INTERPOLATED part, so a site's own multi-line template kept its literal newlines
# and lost the message. It worked until the content mattered.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Notify;
require Lazysite::Util;

sub site {
    my ($site_url) = @_;
    my $d = site_tempdir();
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: Test Site\n";
    print {$cf} "site_url: $site_url\n" if defined $site_url;
    close $cf;
    return $d;
}

# --- SM926: the expansion itself ---------------------------------------------
subtest 'interpolate_env expands only what is allowlisted' => sub {
    local %ENV = ( %ENV, REQUEST_SCHEME => 'https', SERVER_NAME => 'example.test' );
    is( Lazysite::Util::interpolate_env('${REQUEST_SCHEME}://${SERVER_NAME}'),
        'https://example.test', 'the two site_url placeholders expand' );
    is( Lazysite::Util::interpolate_env('${HTTP_HOST}/x'), '${HTTP_HOST}/x',
        'a NON-allowlisted variable is left verbatim, not silently emptied' );
    is( Lazysite::Util::interpolate_env('https://fixed.example'),
        'https://fixed.example', 'a literal is untouched' );
    is( Lazysite::Util::interpolate_env(undef), undef, 'undef survives' );
};

subtest 'Notify expands site_url - the reported defect' => sub {
    local %ENV = ( %ENV, REQUEST_SCHEME => 'https', SERVER_NAME => 'example.test' );
    my $d = site('${REQUEST_SCHEME}://${SERVER_NAME}');
    my $base = Lazysite::Notify::_site_url($d);
    is( $base, 'https://example.test', 'the base is a URL' );
    unlike( $base, qr/\$\{/, 'and carries no unexpanded placeholder' );
};

subtest 'with NO request context the base is empty, not a broken URL' => sub {
    # A cron- or CLI-driven notice has no SERVER_NAME. Interpolation would
    # correctly yield `://` - and emitting that is worse than emitting nothing,
    # because it looks like a link. The template's [% base %]/path then degrades
    # to an absolute PATH, which a reader can still use.
    my %clean = %ENV;
    delete @clean{qw(REQUEST_SCHEME SERVER_NAME)};
    local %ENV = %clean;
    my $d = site('${REQUEST_SCHEME}://${SERVER_NAME}');
    is( Lazysite::Notify::_site_url($d), '',
        'an incomplete expansion yields empty, not "://"' );
};

subtest 'a literal site_url still works without any CGI environment' => sub {
    my %clean = %ENV;
    delete @clean{qw(REQUEST_SCHEME SERVER_NAME)};
    local %ENV = %clean;
    my $d = site('https://fixed.example');
    is( Lazysite::Notify::_site_url($d), 'https://fixed.example',
        'nothing to expand, so nothing is lost' );
};

# --- SM928 defect 1: the store is flattened, the template is not --------------
subtest 'a multi-line message reaches the template whole' => sub {
    my $d   = site('https://fixed.example');
    my $msg = "Name: Jo\nEmail: jo\@example.test\nEnquiry: Other";
    my @sent;
    # `no warnings 'once'`: the package var is mentioned once in this file, and
    # SM912 spent ten failing assertions on a `used only once` warning printing
    # INTO a probe's output where the test read it as the probe's answer. A test
    # that emits noise on STDERR is a test that can lie to the next one.
    no warnings 'once';
    local $Lazysite::Notify::XMPP_SENDER = sub { push @sent, $_[1]; 1 };

    open my $xf, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
    print {$xf} "jid: a\@b\npassword: p\nto: c\@d\n";
    close $xf;
    open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "extensions:\n  - plugins/notify-xmpp.pl\n";
    close $cf;

    Lazysite::Notify::notify( $d,
        { type => 'submission', message => $msg, target => 'enquiry',
            url => '/manager/handlers' } );

    ok( scalar @sent, 'the notice was delivered' ) or return;
    like( $sent[0], qr/Name: Jo/,   'the body carries the first line' );
    like( $sent[0], qr/Enquiry: Other/, 'and the last' );
    like( $sent[0], qr/Name: Jo\n/,
        'WITH the newline between them - the whole of SM928 defect 1' );

    # And the store still holds one record per line, which is its contract.
    open my $lf, '<', "$d/lazysite/logs/notices.jsonl" or die $!;
    my @lines = <$lf>;
    close $lf;
    is( scalar @lines, 1, 'the store holds exactly one line for one notice' );
    like( $lines[0], qr/Name: Jo Email:/,
        'the STORED copy is still flattened - the strip was right about the store' );
};

done_testing();
