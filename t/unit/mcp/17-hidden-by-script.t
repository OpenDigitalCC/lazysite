#!/usr/bin/perl
# SM250: audit_site reports a theme whose content is invisible until a script
# runs.
#
# A scroll-reveal pattern - `.rv { opacity: 0 }` plus a script adding `.in` -
# leaves content invisible to a visitor with JavaScript blocked, to most
# crawlers, and to anything extracting text. It degrades badly on its own terms,
# before anyone breaks it.
#
# It earns a MECHANICAL check because the failure is silent, total below the
# fold, and survives the obvious verification: an agent removed the page script
# while moving chrome into a layout and left every section of a live site
# permanently invisible. The hero sat outside the pattern, so four successive
# visual checks looked fine.
#
# The reduced-motion rule is the trap, not the remedy. It reaches only visitors
# who asked for reduced motion, and reading it as a neutraliser is what caused
# the incident - so it must NOT count as a fallback.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json decode_json);
use IPC::Open2 qw(open2);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;

my $root = "$FindBin::Bin/../../..";
my $mcp  = "$root/lazysite-mcp.pl";

# SM358: the fixture now decides whether anything USES the class, because the
# finding does. `page` is the homepage body and defaults to content that carries
# `.rv` - which is what every SM250 case here was implicitly assuming and none of
# them stated, since the check never looked. `layout_tt` puts the class in a
# template instead, which is the shape the original incident actually took.
sub site_with {
    my (%opt)  = @_;
    my %themes = %{ delete $opt{themes} };
    my $page = exists $opt{page} ? delete $opt{page} : qq(# Home\n\n<div class="rv">Body</div>\n);
    my $tt = delete $opt{layout_tt};
    die 'unknown option: ' . join( ',', sort keys %opt ) if %opt;

    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/auth");
    open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$cf} "site_name: T\nmcp_enabled: true\nlayout: base\n";
    close $cf;
    open my $ix, '>', "$d/index.md" or die $!;
    print {$ix} $page;
    close $ix;
    if ( defined $tt ) {
        make_path("$d/lazysite/layouts/base");
        open my $lf, '>', "$d/lazysite/layouts/base/page.tt" or die $!;
        print {$lf} $tt;
        close $lf;
    }
    for my $t ( sort keys %themes ) {
        make_path("$d/lazysite/layouts/base/themes/$t/assets");
        open my $tj, '>', "$d/lazysite/layouts/base/themes/$t/theme.json" or die $!;
        print {$tj} qq({"name":"$t","version":"1.0.0","layouts":["base"],"config":{}});
        close $tj;
        open my $cs, '>', "$d/lazysite/layouts/base/themes/$t/assets/main.css" or die $!;
        print {$cs} $themes{$t};
        close $cs;
    }
    return $d;
}

sub audit {
    my ($d) = @_;
    my $stub = "$d/users-stub.pl";
    open my $sf, '>', $stub or die $!;
    print $sf <<'STUB';
#!/usr/bin/perl
use strict; use warnings; use JSON::PP qw(encode_json);
print encode_json({ ok => 1, settings => { mcp => 1, manage_content => 1 } });
STUB
    close $sf;
    chmod 0755, $stub;

    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => 'audit_site', arguments => {} } } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = 'Bearer agent:lzs_tok';
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, $mcp );
    print $in $body;
    close $in;
    my $resp = do { local $/; <$out> };
    close $out;
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $r = eval { decode_json( $jb // '' ) };
    return $r && $r->{result} ? $r->{result}{structuredContent} : undef;
}

sub themes_flagged {
    my ($r) = @_;
    return map { $_->{theme} } @{ $r->{hidden_by_script} || [] };
}

# --- the reported pattern is reported ---------------------------------------
{
    my $d = site_with( themes => { reveal => <<'CSS' } );
.rv    { opacity: 0; transform: translateY(22px); }
.rv.in { opacity: 1; transform: none; }
CSS
    my $r = audit($d);
    ok( $r && $r->{ok}, 'audit_site answers' ) or diag encode_json( $r // {} );
    ok( ( grep { $_ eq 'base/reveal' } themes_flagged($r) ),
        'a theme hiding content by default is reported' )
        or diag encode_json( $r->{hidden_by_script} // [] );
}

# --- prefers-reduced-motion is NOT a fallback -------------------------------
# The specific thing that misled a careful reader. If this stopped counting as a
# finding, the guard would miss the exact case it was built for.
{
    my $d = site_with( themes => { reveal => <<'CSS' } );
.rv    { opacity: 0; }
.rv.in { opacity: 1; }
@media (prefers-reduced-motion: reduce) { .rv { opacity: 1; } }
CSS
    my $r = audit($d);
    ok( ( grep { $_ eq 'base/reveal' } themes_flagged($r) ),
        'a reduced-motion rule does not excuse it - it reaches only visitors who '
            . 'asked for reduced motion' );
}

# --- a real no-JS fallback IS accepted --------------------------------------
# The pattern is legitimate with one, so flagging it would be the false positive
# that trains an operator to ignore this.
{
    my $d = site_with( themes => { reveal => <<'CSS' } );
.rv    { opacity: 0; }
.rv.in { opacity: 1; }
.no-js .rv { opacity: 1; }
CSS
    my $r = audit($d);
    is( scalar( grep { $_ eq 'base/reveal' } themes_flagged($r) ), 0,
        'a .no-js fallback is accepted' );
}

# --- an ordinary theme is untouched -----------------------------------------
{
    my $d = site_with( themes => { plain => "body { color: #222; }\n.card { opacity: 1; }\n" } );
    my $r = audit($d);
    is_deeply( $r->{hidden_by_script}, [],
        'a theme that hides nothing raises nothing' );
}

# --- opacity: 0.5 is not opacity: 0 -----------------------------------------
# A decimal must not be read as the zero case, or every faded element is a
# finding.
{
    my $d = site_with( themes => { faded => ".muted { opacity: 0.55; }\n" } );
    my $r = audit($d);
    is_deeply( $r->{hidden_by_script}, [],
        'a fractional opacity is not the hidden-by-default pattern' );
}

# --- visibility: hidden counts too ------------------------------------------
{
    my $d = site_with( themes => { vis => ".rv { visibility: hidden; }\n.rv.in { visibility: visible; }\n" } );
    my $r = audit($d);
    ok( ( grep { $_ eq 'base/vis' } themes_flagged($r) ),
        'visibility:hidden is the same failure in a different property' );
}

# --- SM358: a mechanism nothing uses is not a finding ------------------------
# The whole of SM358. The reporting instance had a theme defining `.reveal` and
# no page using it, so the operator was shown an item they could not clear: the
# theme is shipped, an edit is overwritten on upgrade, and there was nothing
# else to change. An audit people learn to ignore is worse than no audit.
{
    my $d = site_with(
        themes => { reveal => ".rv { opacity: 0; }\n.rv.in { opacity: 1; }\n" },
        page   => "# Home\n\nOrdinary copy, no reveal class anywhere.\n",
    );
    my $r = audit($d);
    is_deeply( $r->{hidden_by_script}, [],
        'a theme that CAN hide content, on a site where nothing does, is silent' )
        or diag encode_json( $r->{hidden_by_script} // [] );
}

# --- SM358: and it names what to look at -------------------------------------
{
    my $d = site_with(
        themes => { reveal => ".rv { opacity: 0; }\n.rv.in { opacity: 1; }\n" },
        page   => qq(# Home\n\n<div class="rv">Below the fold</div>\n),
    );
    my $r = audit($d);
    my ($f) = @{ $r->{hidden_by_script} || [] };
    # No 'or return' here - a bare block is not a sub, so a return would be a
    # runtime error rather than a skip. Guard the dependent assertions instead.
    ok( $f, 'a page using the class is a finding' );
    if ($f) {
        is_deeply( $f->{classes}, ['rv'], 'the class doing the hiding is named' );
        is_deeply( $f->{used_by}, ['/index'],
            'and the page that uses it, so the operator has somewhere to go' );
    }
}

# --- SM358: the LAYOUT case, which is the incident ---------------------------
# SM250 was a layout emitting the class on every section while the hero sat
# outside the pattern. Checking page content alone would have missed exactly the
# case this check was built for, so the templates are read too.
{
    my $d = site_with(
        themes    => { reveal => ".rv { opacity: 0; }\n.rv.in { opacity: 1; }\n" },
        page      => "# Home\n\nThe page itself says nothing about classes.\n",
        layout_tt => qq(<body><div class="rv">[% content %]</div></body>\n),
    );
    my $r = audit($d);
    my ($f) = @{ $r->{hidden_by_script} || [] };
    ok( $f, 'a layout emitting the class is a finding' )
        or diag encode_json( $r->{hidden_by_script} // [] );

    # SM358 follow-up: the TEMPLATE, not the layout. Reporting "layout:base"
    # was true and unhelpful - on the field instance four of six components
    # applied the class and two did not, so an operator was handed six files to
    # read when one was implicated. The fixture's template is page.tt.
    is_deeply( $f->{used_by}, ['base/page'],
        'named as the template that applies it, not the layout that holds it' )
        if $f;
}

subtest 'and it names the COMPONENT when a component is the one applying it' => sub {
    # The field shape exactly: the layout's own template mentions the class
    # only in JavaScript, and a component applies it in markup. Reporting the
    # layout sends the operator to the wrong file.
    my $d = site_with(
        themes => { reveal => ".rv { opacity: 0; }\n.rv.in { opacity: 1; }\n" },
        page   => "# Home\n\nNo classes here.\n",
        layout_tt => qq(<body>[% content %]<script>document.querySelectorAll('.rv')</script></body>\n),
    );
    make_path("$d/lazysite/layouts/base/components");
    open my $c, '>', "$d/lazysite/layouts/base/components/features.tt" or die $!;
    print {$c} qq(<section class="rv feature">[% item %]</section>\n);
    close $c;

    my $r = audit($d);
    my ($f) = @{ $r->{hidden_by_script} || [] };
    ok( $f, 'still a finding' ) or diag encode_json( $r->{hidden_by_script} // [] );
    is_deeply( $f->{used_by}, ['base/components/features'],
        'the component is named, and the layout - whose only reference is '
            . 'JavaScript - is not' )
        if $f;
};

done_testing();
