package Odoo::Ops::ResetForm;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;

=head1 NAME

Odoo::Ops::ResetForm - Odoo's password-reset page, read and submitted as a person's browser does

=head1 SYNOPSIS

    my $l    = Odoo::Ops::ResetForm->parse_link($link);   # { url, path, token, db }
    my $web  = $client->web_session;
    my $page = Odoo::Ops::ResetForm->read( $web, db => $db, token => $token );
    if ( $page->{kind} eq 'form' ) {                     # login, name, csrf, token
        my $r = Odoo::Ops::ResetForm->submit( $web, $page, password => $pw );
    }

=head1 DESCRIPTION

C</web/reset_password> is a public route of auth_signup (16, 18 and 19, read
in the sources of each): a GET with C<token> renders a form carrying the
user's C<login> and C<name> and a C<csrf_token> bound to the session cookie;
a POST of C<csrf_token>, C<token>, C<login>, C<name>, C<password> and
C<confirm_password> runs C<res.users.signup>, which sets the password and
makes the token useless. The page is read with a regular expression per
input, not an HTML parser: the form is Odoo's own template and the fields
are named.

C<kind> of a read page is C<form> (a reset form; its C<login> is undef where the series' form does not name the user, as on 19), C<invalid-token> (Odoo's
own "Invalid signup token" alert) or C<other> (anything else: a 404, a login
page, a signup form, a database error), with C<status> and, for C<other>, a
C<what> that names it.

=head1 METHODS

=head2 parse_link($link)

C<< { url, path, token, db } >> of a link: C<url> is scheme, host and port
without a trailing slash, C<path> the path, C<token> and C<db> the query
values (undef when absent). A string that is not an http(s) URL dies as
C<usage>, naming it without the token.

=cut

sub parse_link ($class, $link) {
    my ( $url, $path, $query ) = ( $link // '' ) =~ m{\A(https?://[^/?#\s]+)(/[^?#\s]*)?(?:\?([^#\s]*))?(?:#.*)?\z}i
        or Odoo::Error->throw( kind => 'usage', message => 'the link is not an http(s) URL (https://host/web/reset_password?db=...&token=...)' );
    my %q;
    for my $pair ( split /&/, $query // '' ) {
        my ( $k, $v ) = split /=/, $pair, 2;
        next if !defined $k || $k eq '';
        $q{ _unescape($k) } //= _unescape( $v // '' );
    }
    return { url => $url =~ s{/+\z}{}r, path => $path // '/', token => $q{token}, db => $q{db} };
}

sub _unescape ($s) {
    $s =~ tr/+/ /;
    $s =~ s/%([0-9A-Fa-f]{2})/chr hex $1/ge;
    return $s;
}

sub _escape ($s) {
    $s =~ s/([^A-Za-z0-9._~-])/sprintf '%%%02X', ord $1/ge;
    return $s;
}

=head2 same_origin($a, $b)

True when two C<scheme://host[:port]> strings name the same instance, a
default port (443, 80) counting as none.

=cut

sub same_origin ($class, $a, $b) {
    my $norm = sub ($u) {
        my ( $s, $h, $p ) = lc( $u =~ s{/+\z}{}r ) =~ m{\A(https?)://([^/:]+)(?::(\d+))?\z} or return $u;
        $p //= $s eq 'https' ? 443 : 80;
        return "$s://$h:$p";
    };
    return $norm->($a) eq $norm->($b) ? 1 : 0;
}

=head2 prefix($token)

The first six characters of a token and an ellipsis: what screens and
journals say of it.

=cut

sub prefix ($class, $token) { substr( $token // '', 0, 6 ) . '...' }

=head2 scrub($text, $token)

C<$text> with the whole token replaced by its prefix (Odoo quotes it in some
of its messages).

=cut

sub scrub ($class, $text, $token) {
    return $text if !defined $text || !defined $token || $token eq '';
    my $p = $class->prefix($token);
    $text =~ s/\Q$token\E/$p/g;
    return $text;
}

=head2 read($web, db => D, token => T)

GET the form with the session C<$web> (its cookies are kept for the POST) and
say what it is.

=cut

sub read ( $class, $web, %o ) {
    return { status => 0, kind => 'other', what => 'the link carries no token' } if !defined $o{token} || $o{token} eq '';
    my $path = '/web/reset_password?' . join '&', ( defined $o{db} && $o{db} ne '' ? 'db=' . _escape( $o{db} ) : () ), 'token=' . _escape( $o{token} );
    my $res    = $web->get($path);
    my $status = $res->{status} // 0;
    my $html   = $res->{content} // '';
    my %page   = ( status => $status );
    if ( $status =~ /^3/ ) {
        my $to = $res->{headers}{location} // 'no location';
        $to =~ s/[?#].*//s;
        return { %page, kind => 'other', what => "Odoo redirected to $to (HTTP $status)" };
    }
    return { %page, kind => 'other', what => "Odoo answered HTTP $status" } if $status != 200;
    my $in    = _inputs($html);
    my $error = _alert( $html, 'danger' );
    return { %page, kind => 'invalid-token', error => $error }
        if defined $error && $error =~ /invalid signup token|not valid or expired|no longer valid/i && !exists $in->{password};
    # 16 and 18 show the user's login and name (read-only fields); 19's form asks for the passwords alone
    if ( exists $in->{password} && exists $in->{confirm_password} && length( $in->{csrf_token} // '' ) && length( $in->{token} // '' ) ) {
        return { %page, kind => 'form', login => ( length( $in->{login} // '' ) ? $in->{login} : undef ), name => $in->{name} // '', csrf => $in->{csrf_token}, token => $in->{token},
            ( defined $error ? ( error => $error ) : () ) };
    }
    return { %page, kind => 'other', what => defined $error ? "the page says: $error" : 'the page is not a password-reset form' };
}

=head2 submit($web, $page, password => P)

POST the form read by C<read> (the same session) and answer
C<< { ok, error, status } >>. C<ok> says only that Odoo did not complain; the
password is proved by signing in with it, which the caller does.

=cut

sub submit ( $class, $web, $page, %o ) {
    my $res = $web->post_form( '/web/reset_password', {
        csrf_token => $page->{csrf}, token => $page->{token}, redirect => '',
        login => $o{login} // $page->{login} // '', name => $page->{name},
        password => $o{password}, confirm_password => $o{password},
    } );
    my $status = $res->{status} // 0;
    return { ok => 1, status => $status } if $status =~ /^3/;
    return { ok => 0, status => $status, error => "Odoo answered HTTP $status" } if $status != 200;
    my $html  = $res->{content} // '';
    my $error = _alert( $html, 'danger' );
    return { ok => 0, status => $status, error => $error } if defined $error;
    return { ok => 1, status => $status, message => _alert( $html, 'success' ) };
}

# every <input> of the page by name => value
sub _inputs ($html) {
    my %v;
    while ( $html =~ /<input\b([^>]*)>/gis ) {
        my $attrs = $1;
        my %a;
        $a{ lc $1 } = _text( $2 // $3 // '' ) while $attrs =~ /([\w-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;
        $v{ $a{name} } //= $a{value} // '' if defined $a{name};
    }
    return \%v;
}

# the text of the first <p class="alert alert-KIND">, tags stripped
sub _alert ( $html, $kind ) {
    $html =~ m{<p\b[^>]*class="[^"]*\balert-\Q$kind\E\b[^"]*"[^>]*>(.*?)</p>}is or return undef;
    my $t = $1;
    $t =~ s/<[^>]+>//g;
    $t = _text($t);
    $t =~ s/\s+/ /g;
    $t =~ s/^ | $//g;
    return $t;
}

sub _text ($s) {
    $s =~ s/&#(\d+);/chr $1/ge;
    $s =~ s/&#x([0-9a-fA-F]+);/chr hex $1/ge;
    $s =~ s/&quot;/"/g;
    $s =~ s/&lt;/</g;
    $s =~ s/&gt;/>/g;
    $s =~ s/&amp;/&/g;
    return $s;
}

1;
