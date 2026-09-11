package Lazysite::Remap;

# SM802: per-domain prefix redirects, for a site replacing another on the same
# hostname while links to the old one are still in the world.
#
# RULED 2026-09-09: per-domain and operator-only - a rule sends a visitor to
# another host, the same class of authority as a connector's destination
# (SM579); counts DERIVED from the visitor log, one source and no write on the
# request path; an extension doing one bounded act, every generalisation refused
# by default.
#
# THE DESTINATION NEVER COMES FROM THE REQUEST. It is read from this file and
# nowhere else. A `?to=` convenience would make every lazysite an open redirect,
# and the reporter asked for that written down so nobody adds it later as an
# obvious kindness. This is where it is written down.
#
# The rules file, lazysite/remap/rules.conf - one rule per line, file order is match
# order, `#` starts a comment:
#
#   <host>  <prefix>  <destination>  [301|302]
#   www.example.com  /web       https://backend.example.com
#   www.example.com  /helpdesk  https://backend.example.com/helpdesk  301
#
# This module is the one implementation. The render path is module-free (ADR
# 0001) and carries a MARKED COPY of parse and match; t/lint/129 runs both over
# the same text and fails if they accept different rules.

use strict;
use warnings;
use Exporter 'import';
use Fcntl    qw(O_WRONLY O_CREAT O_TRUNC);
use JSON::PP ();

our @EXPORT_OK = qw(parse_rules match_rule rules_path read_rules_text write_rules report);

my $HOST_RE = qr/\A [a-z0-9] (?:[a-z0-9-]*[a-z0-9])? (?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)* \z/x;

# A DIRECTORY, not a file beside the others, so the extension's owns.storage
# claim cannot also match a sibling whose name merely starts the same way.
sub rules_path { my ($lzdir) = @_; return "$lzdir/remap/rules.conf" }

# A prefix is a path, matched on a SEGMENT boundary: /web matches /web and
# /web/login and never /website-terms, which is the mistake a startsWith makes.
sub _valid_prefix {
    my ($p) = @_;
    return 0 unless defined $p && $p =~ m{\A/};
    return 0 if $p =~ /[\s?#"'<>\\]/;
    return 0 if $p =~ m{(?:\A|/)\.\.(?:/|\z)};
    return 0 if $p =~ m{//};
    return 1;
}

# A destination is an absolute http(s) URL, or an absolute path on this site.
# Never protocol-relative (`//host` is another host wearing a path's clothes),
# never with whitespace, quotes or line breaks - it becomes a Location header.
sub _valid_destination {
    my ($d) = @_;
    return 0 unless defined $d && length $d;
    return 0 if $d =~ /[\s"'<>\\]/;
    return 1 if $d =~ m{\Ahttps?://[A-Za-z0-9.-]+(?::\d{1,5})?(?:[/?].*)?\z};
    return 1 if $d =~ m{\A/(?!/)};
    return 0;
}

# Returns ( \@rules, \@errors ). A rule is { host, prefix, dest, code, line }.
# Errors name the line and say what is wrong with it; a line with an error is not
# a rule, and the caller decides whether that refuses a save.
sub parse_rules {
    my ($text) = @_;
    my ( @rules, @errors, %seen );
    my $n = 0;
    for my $raw ( split /\r?\n/, ( $text // '' ) ) {
        $n++;
        ( my $l = $raw ) =~ s/#.*\z//;
        $l =~ s/^\s+|\s+$//g;
        next unless length $l;
        my @f = split /\s+/, $l;
        if ( @f < 3 || @f > 4 ) {
            push @errors, "line $n: expected host, prefix, destination and an optional 301 or 302";
            next;
        }
        my ( $host, $prefix, $dest, $code ) = @f;
        $host = lc $host;
        $code //= 302;
        if ( $host !~ $HOST_RE ) { push @errors, "line $n: '$host' is not a host name"; next }
        if ( !_valid_prefix($prefix) ) { push @errors, "line $n: '$prefix' is not a path prefix starting with /"; next }
        if ( !_valid_destination($dest) ) { push @errors, "line $n: '$dest' is not an http(s) URL or an absolute path on this site"; next }
        if ( $code !~ /\A30[12]\z/ ) { push @errors, "line $n: status '$code' is not 301 or 302"; next }
        $prefix =~ s{(?<=.)/\z}{};    # /web/ and /web are the same prefix
        if ( $seen{"$host $prefix"}++ ) { push @errors, "line $n: $host $prefix is already a rule above"; next }
        push @rules, { host => $host, prefix => $prefix, dest => $dest, code => $code + 0, line => $n };
    }
    return ( \@rules, \@errors );
}

# The first rule for this host whose prefix matches this path on a segment
# boundary, and the Location it sends to - path remainder and query preserved.
# Returns ( $rule, $location ) or ().
sub match_rule {
    my ( $rules, $host, $path, $query ) = @_;
    return unless defined $host && length $host && defined $path;
    for my $r (@$rules) {
        next unless $r->{host} eq $host;
        my $p = $r->{prefix};
        my $rest;
        if    ( $p eq '/' )                  { $rest = $path }
        elsif ( $path eq $p )                { $rest = '' }
        elsif ( index( $path, "$p/" ) == 0 ) { $rest = substr( $path, length $p ) }
        else                                 { next }
        ( my $base = $r->{dest} ) =~ s{/\z}{};
        my ( $dpath, $dq ) = split /\?/, $base, 2;
        my $loc = $dpath . $rest;
        my @q   = grep { defined && length } ( $dq, $query );
        $loc .= '?' . join( '&', @q ) if @q;
        $loc =~ s/[\r\n]//g;
        return ( $r, $loc );
    }
    return;
}

sub read_rules_text {
    my ($lzdir) = @_;
    open my $fh, '<:utf8', rules_path($lzdir) or return '';
    local $/;
    my $t = <$fh>;
    close $fh;
    return $t // '';
}

# Writes only text that parses with no errors - a file the render path would
# half-apply is a file that says it redirects and does not.
sub write_rules {
    my ( $lzdir, $text )   = @_;
    my ( $rules, $errors ) = parse_rules($text);
    return { ok => 0, kind => 'invalid', error => join( '; ', @$errors ), errors => $errors }
        if @$errors;
    my $path = rules_path($lzdir);
    my $dir  = $path =~ s{/[^/]+\z}{}r;
    mkdir $dir unless -d $dir;
    my $tmp = "$path.tmp.$$";
    sysopen( my $fh, $tmp, O_WRONLY | O_CREAT | O_TRUNC, 0640 )
        or return { ok => 0, error => "cannot write $path: $!" };
    binmode $fh, ':utf8';
    print {$fh} $text;
    print {$fh} "\n" unless $text =~ /\n\z/;
    close $fh or return { ok => 0, error => "cannot write $path: $!" };
    rename $tmp, $path or do { unlink $tmp; return { ok => 0, error => "cannot write $path: $!" } };
    return { ok => 1, rules => scalar @$rules };
}

# THE COUNTS, DERIVED. Every redirect this module causes is recorded in the
# first-party access log with the rule's prefix in `rr` and the host in `h`; the
# count and the last-used date are read back from there. The LAST-USED DATE is the
# load-bearing one: a migration rule exists to cover links already in the world,
# and when the last has been followed the rule can go. Without it the only safe
# answer is to keep every rule forever.
#
# A report with no log to read says so rather than reporting zero: "nothing was
# followed" and "nothing was recorded" are different answers, and only one of
# them means a rule can go.
sub report {
    my ($lzdir) = @_;
    my ( $rules, $errors ) = parse_rules( read_rules_text($lzdir) );
    my %stat = map { ( "$_->{host} $_->{prefix}" => { hits => 0, last => undef } ) } @$rules;
    my @files = sort glob "$lzdir/logs/access-*.jsonl";
    for my $f (@files) {
        open my $fh, '<', $f or next;
        while ( my $l = <$fh> ) {
            next unless index( $l, '"rr":' ) >= 0;
            my $rec = eval { JSON::PP::decode_json($l) } or next;
            my $k   = ( $rec->{h} // '' ) . ' ' . ( $rec->{rr} // '' );
            next unless $stat{$k};
            $stat{$k}{hits}++;
            $stat{$k}{last} = $rec->{t}
                if !defined $stat{$k}{last} || $rec->{t} > $stat{$k}{last};
        }
        close $fh;
    }
    my @out = map {
        my $s = $stat{"$_->{host} $_->{prefix}"};
        +{ %$_, hits => $s->{hits}, last_used => $s->{last} } # `+{`: a bare { here is a BLOCK, and the report came back as a flat key/value list
    } @$rules;
    return {
        ok       => 1,
        rules    => \@out,
        errors   => $errors,
        recorded => ( @files ? JSON::PP::true : JSON::PP::false ),
        note     => @files ? undef
        : 'No visitor log to count from - the first-party access log is not recording '
            . '(the stats extension is off, or first_party: off), so these rules have no '
            . 'counts. That is not the same as nobody following them.',
    };
}

1;
