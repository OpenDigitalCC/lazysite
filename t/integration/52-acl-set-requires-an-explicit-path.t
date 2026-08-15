#!/usr/bin/perl
# SM306: acl-set will not take the whole site private because an argument was
# left out.
#
# THE DEFECT. The control API derives its target once, at the top of the
# dispatcher, for every action:
#
#     my $path = $params{path} // '/';
#
# That default is right for `list`, which should list the site root when asked
# for nothing in particular, and harmless for acl-get and acl-remove. acl-set
# inherited it, where the same omission applies a SITE-WIDE read restriction and
# returns ok:1.
#
# Before SM287 a root entry sat inert, so this was a no-op. SM287 shipped in
# 0.10.8 and made a root rule take effect. The default has been hazardous since,
# and a partner agent found it the direct way: they put the path in the JSON
# body, where `save` and `domain-add` take their arguments, acl-set discarded it
# in silence, and edge answered 302 to every anonymous request until the rule
# was removed about a minute later.
#
# WHAT MAKES IT WORTH A TEST. SM287 was careful about every OTHER spelling of the
# root: `/` is canonical, '', '.' and './' normalise to it, and glob spellings
# are refused with a message naming `/`, on the reasoning that accepting `*`
# would imply a matching language the store does not have. That care was applied
# to every way of saying "the whole site" except saying nothing at all - so the
# most destructive available target was the one you got by omitting an argument.
#
# The direction of failure is what decides this. acl-remove keeps its default,
# because its failure direction is to UN-protect the root, which is what recovery
# looks like; a test below holds that, so a fix aimed at safety cannot make the
# site harder to rescue than to break.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root env_passthrough);

my $root    = repo_root();
my $docroot = tempdir( CLEANUP => 1 );
mkdir "$docroot/lazysite"        or die $!;
mkdir "$docroot/lazysite/themes" or die $!;
mkdir "$docroot/section"         or die $!;

open my $cf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;

open my $pf, '>', "$docroot/section/index.md" or die $!;
print $pf "---\ntitle: Section\n---\n\nBody.\n";
close $pf;

sub cgi_env {
    return (
        env_passthrough(),
        DOCUMENT_ROOT         => $docroot,
        HTTP_X_REMOTE_USER    => 'testmgr',
        LAZYSITE_AUTH_TRUSTED => 1,
    );
}

sub csrf_token {
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET',
        QUERY_STRING => 'action=csrf-token' );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return decode_json($out)->{token};
}

my $TOKEN = csrf_token();

# POST a JSON body to the API and return the decoded reply.
sub api_post {
    my ( $qs, $payload ) = @_;
    my $body = encode_json($payload);
    my $tmp  = "$docroot/.post-body";
    open my $bf, '>', $tmp or die $!;
    print $bf $body;
    close $bf;

    local %ENV = (
        cgi_env(),
        REQUEST_METHOD    => 'POST',
        QUERY_STRING      => $qs,
        CONTENT_TYPE      => 'application/json',
        CONTENT_LENGTH    => length($body),
        HTTP_X_CSRF_TOKEN => $TOKEN,
    );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E < \Q$tmp\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $d = eval { decode_json($out) };
    return $d || { ok => 0, error => "unparseable reply: $out" };
}

sub api_get {
    my ($qs) = @_;
    local %ENV = ( cgi_env(), REQUEST_METHOD => 'GET', QUERY_STRING => $qs );
    my $out = qx($^X \Q$root/lazysite-manager-api.pl\E 2>/dev/null);
    $out =~ s/\A.*?\r?\n\r?\n//s;
    my $d = eval { decode_json($out) };
    return $d || { ok => 0, error => "unparseable reply: $out" };
}

subtest 'acl-set with no path is refused' => sub {
    my $d = api_post( 'action=acl-set', { read => ['alice'], write => ['alice'] } );

    ok( !$d->{ok}, 'the call is refused rather than applied to the whole site' )
        or diag( 'Reply: ' . encode_json($d) );

    # The message has to teach the right thing. A bare "path required" would send
    # the caller looking for a missing feature; what they need to know is that
    # site-wide is still available and is spelled out loud.
    like( $d->{error} // '', qr{\bpath=/|path\s*=\s*/},
        'and the message names path=/ as the way to say site-wide' );

    # Nothing was written. This is the assertion that matters - a refusal that
    # still stored the rule would be the same defect wearing an error message.
    my $g = api_get('action=acl-get&path=/');
    ok( !( $g->{acl} && ( @{ $g->{acl}{read} || [] } || @{ $g->{acl}{write} || [] } ) ),
        'and no root rule was written' )
        or diag( 'Root ACL after the refused call: ' . encode_json($g) );
};

subtest 'a path in the JSON body is refused, naming the key' => sub {
    # The body/query split is what invited the original mistake: `save` takes its
    # content from the body and `domain-add` takes host, content_root and the
    # rest from the body, so a caller who has just used those has been taught
    # where arguments go. acl-set read its lists from the body and its path from
    # the query string, and discarded the body key without a word.
    my $d = api_post( 'action=acl-set',
        { path => '/section/', read => ['alice'], write => ['alice'] } );

    ok( !$d->{ok}, 'the call is refused rather than silently retargeted' )
        or diag( 'Reply: ' . encode_json($d) );
    like( $d->{error} // '', qr/\bpath\b/,
        'and the message names the key that was ignored' );

    my $g = api_get('action=acl-get&path=/');
    ok( !( $g->{acl} && ( @{ $g->{acl}{read} || [] } || @{ $g->{acl}{write} || [] } ) ),
        'and no root rule was written' );
};

subtest 'an explicit site-wide rule still works' => sub {
    # The capability is not being removed - only the accident. SM287 made a root
    # rule effective on purpose, and its warning text is part of that feature.
    my $d = api_post( 'action=acl-set&path=/',
        { read => ['alice'], write => ['alice'] } );

    ok( $d->{ok}, 'acl-set with path=/ is accepted' )
        or diag( 'Reply: ' . encode_json($d) );
    like( join( ' ', @{ $d->{warnings} || [] } ), qr/site-wide/i,
        'and still carries the SM287 root warning' );

    my $g = api_get('action=acl-get&path=/');
    is_deeply( $g->{acl}{read}, ['alice'], 'the root rule is stored' );
};

subtest 'recovery stays at least as easy as the mistake' => sub {
    # acl-remove KEEPS its default. Its direction of failure is to un-protect the
    # root, which is what recovery looks like - so requiring an explicit path
    # here would make rescuing a site harder than breaking it, which is the wrong
    # way round for a safety change.
    my $d = api_post( 'action=acl-remove', {} );
    ok( $d->{ok}, 'acl-remove with no path still clears the root rule' )
        or diag( 'Reply: ' . encode_json($d) );

    my $g = api_get('action=acl-get&path=/');
    ok( !( $g->{acl} && @{ $g->{acl}{read} || [] } ),
        'and the site is public again' );
};

subtest 'the reading actions are unchanged' => sub {
    # The shared default is the cause, and narrowing it for every action is the
    # larger change SM306 defers. These hold the line meanwhile: whatever is done
    # to acl-set must not disturb the actions the default was chosen for.
    my $l = api_get('action=list');
    ok( $l->{ok}, 'list with no path still lists the site root' )
        or diag( 'Reply: ' . encode_json($l) );

    my $g = api_get('action=acl-get');
    ok( $g->{ok}, 'acl-get with no path still reads the root rule' )
        or diag( 'Reply: ' . encode_json($g) );
};

done_testing();
