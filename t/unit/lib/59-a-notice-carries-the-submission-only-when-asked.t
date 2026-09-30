#!/usr/bin/perl
# SM928 defects 2 and 3, and the ruling that governs them.
#
# Defect 2: the notifier received the form's NAME and nothing else, so the
# documented override at lazysite/notify-templates/submission.xmpp.tt could restyle
# seven variables that did not include a single submitted field. The extension point
# was real, reached, and could not express the one thing an operator wanted from it.
#
# Defect 3: a multi-line default body, which defect 1 made possible and defect 2
# gave something to say.
#
# THE RULING (2026-09-30) IS OPT-IN PER FORM, and the first subtest is the one that
# matters most: a form that has not asked must emit EXACTLY what it emitted before.
# The alternative - full content by default - means every site that upgrades starts
# broadcasting customer-written text into whatever chat room it was configured with,
# on the strength of a setting made when the notice was one line long. So the
# no-fields case is asserted as a NEGATIVE, not inferred from the positive passing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

require Lazysite::Notify;

sub site {
    my $d = site_tempdir();
    make_path("$d/lazysite/logs");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: Test Site\nsite_url: https://fixed.example\n";
    print {$cf} "extensions:\n  - plugins/notify-xmpp.pl\n";
    close $cf;
    open my $xf, '>', "$d/lazysite/notify-xmpp.conf" or die $!;
    print {$xf} "jid: a\@b\npassword: p\nto: c\@d\n";
    close $xf;
    return $d;
}

# Deliver one notice and return what the transport was handed.
sub delivered {
    my (%n) = @_;
    my $d = site();
    my @sent;
    no warnings 'once';
    local $Lazysite::Notify::XMPP_SENDER = sub { push @sent, $_[1]; 1 };
    Lazysite::Notify::notify( $d,
        { type => 'submission', message => 'New form submission: enquiry',
            target => 'enquiry', url => '/manager/handlers', %n } );
    return $sent[0] // '';
}

my @FIELDS = (
    { name => 'name',    label => 'Name',    value => 'Jo Bloggs',        truncated => 0 },
    { name => 'email',   label => 'Email',   value => 'jo@example.test',  truncated => 0 },
    { name => 'enquiry', label => 'Enquiry', value => "Line one\nLine two", truncated => 0 },
);

subtest 'NO fields: byte-for-byte the one-line notice a site already gets' => sub {
    my $body = delivered();
    is( $body, 'Test Site: New form submission: enquiry -> https://fixed.example/manager/handlers',
        'exactly the old single line, with nothing added' );
    unlike( $body, qr/\n/, 'and no newline, so a form that never opted in is untouched' );
};

subtest 'WITH fields: the submission is in the body' => sub {
    my $body = delivered( fields => \@FIELDS );
    like( $body, qr/^Test Site: New form submission: enquiry$/m, 'the headline survives' );
    like( $body, qr/^Name: Jo Bloggs$/m,            'a field appears as label and value' );
    like( $body, qr/^Email: jo\@example\.test$/m,   'and so does the next' );
    like( $body, qr/^Enquiry: Line one$/m,          'a multi-line value keeps its first line' );
    like( $body, qr/^Line two$/m,                   'and its second' );
    like( $body, qr{^Read it: https://fixed\.example/manager/handlers$}m,
        'and the link is last, expanded, and named' );
    unlike( $body, qr/Name  +:/, 'labels are NOT padded into columns' );
};

subtest 'a truncated field says so' => sub {
    my $body = delivered( fields =>
            [ { name => 'msg', label => 'Message', value => 'x' x 20, truncated => 1 } ] );
    like( $body, qr/^Message: x+ \[\.\.\.\]$/m,
        'the marker is on the line, so a reader knows to follow the link' );
};

subtest 'the structure is available to a site template, not just the text' => sub {
    my $d = site();
    make_path("$d/lazysite/notify-templates");
    open my $tf, '>', "$d/lazysite/notify-templates/submission.xmpp.tt" or die $!;
    # A site template gets real Template Toolkit, so it can loop - which is the
    # whole reason `fields` crosses the call as VALUES rather than as a block.
    print {$tf} "[% FOREACH f IN fields %][% f.name %]=[% f.value %];[% END %]";
    close $tf;
    my @sent;
    no warnings 'once';
    local $Lazysite::Notify::XMPP_SENDER = sub { push @sent, $_[1]; 1 };
    Lazysite::Notify::notify( $d,
        { type => 'submission', message => 'ignored by this template',
            target => 'enquiry', fields => \@FIELDS } );
  SKIP: {
        skip 'Template is not installed on this host', 2
            unless eval { require Template; 1 };
        like( $sent[0] // '', qr/name=Jo Bloggs;/, 'a template can iterate the fields' );
        like( $sent[0] // '', qr/email=jo\@example\.test;/, 'all of them' );
    }
};

# NOT a gate on the newline strip, and saying so because it looks like one. A
# sabotage pass removed the strip and this still passed: encode_json escapes a
# newline as \n, so the store is one record per line either way. What this asserts
# is the store's format, which is worth pinning on its own - it just is not
# evidence that the strip is doing anything for it.
subtest 'the bell store holds one line per notice, whatever the message' => sub {
    my $d = site();
    no warnings 'once';
    local $Lazysite::Notify::XMPP_SENDER = sub { 1 };
    Lazysite::Notify::notify( $d,
        { type => 'submission', message => "a\nb", target => 'enquiry',
            fields => \@FIELDS } );
    open my $lf, '<', "$d/lazysite/logs/notices.jsonl" or die $!;
    my @lines = <$lf>;
    close $lf;
    is( scalar @lines, 1, 'one record, one line - the store contract is unchanged' );
};

done_testing();
