#!/usr/bin/perl -w
use strict;

use lib '/Users/btrott/Documents/devel/faved-tp';
use lib '/Users/btrott/Documents/devel/WWW-TypePad/lib';

use Faved::Util;
use JSON;
use List::Util qw( first );
use Plack::App::File;
use Plack::App::URLMap;
use Plack::Builder;
use Template;
use Template::Provider::Encoding;
use Template::Stash::ForceUTF8;
use WWW::TypePad;

my $dbh = Faved::Util->get_dbh;
my $tt = Template->new(
    LOAD_TEMPLATES  => [
        Template::Provider::Encoding->new( INCLUDE_PATH => 'templates' )
    ],
    STASH           => Template::Stash::ForceUTF8->new,
);
my $tp = WWW::TypePad->new;

my $error = sub {
    my( $code, $html ) = @_;
    return [
        $code,
        [ 'Content-Type', 'text/html' ],
        [ $html ],
    ];
};

sub load_assets_by {
    my( $sql, @bind ) = @_;

    # Used for calculating human-readable date strings in the asset
    # loop below.
    my $dt = DateTime::Format::Human::Duration->new;
    my $now = DateTime->now( time_zone => 'America/Los_Angeles' );

    my $sth = $dbh->prepare( <<SQL );
SELECT a.asset_id,
       a.api_id,
       a.title,
       a.content,
       a.permalink,
       a.favorite_count,
       UNIX_TIMESTAMP(CONVERT_TZ(a.created, '+00:00', 'SYSTEM')) AS created,
       a.links_json,
       a.object_type AS type,
       p.api_id AS person_api_id,
       p.display_name,
       p.avatar_uri
FROM asset a
JOIN person p ON p.person_id = a.person_id
$sql
SQL
    $sth->execute( @bind );

    my( @assets, %id2idx );
    while ( my $row = $sth->fetchrow_hashref ) {
        $row->{author} = {
            api_id          => delete $row->{person_api_id},
            display_name    => delete $row->{display_name},
            avatar_uri      => delete $row->{avatar_uri},
        };

        $row->{favorited_by} = [];

        $row->{published} = $dt->format_duration_between(
            $now, DateTime->from_epoch( epoch => $row->{created} )
        );

        # Calculate an excerpt, extract media, etc, and stuff it all
        # into the "content" key.
        $row->{content} = Faved::Util->get_content_data(
            $row->{type},
            $row->{content},
            decode_json( $row->{links_json} ),
        );

        push @assets, $row;
        $id2idx{ $row->{asset_id} } = $#assets;
    }
    $sth->finish;

    # For each asset that we found, we want a list of the users who've
    # added the asset as a favorite. Construct a complex IN clause to
    # load the user records for display, and add them to the "favorited_by"
    # key in each asset row.
    my @ids = keys %id2idx;
    if ( @ids ) {
        my $in_sql = join ', ', ( '?' ) x @ids;
        my $sth = $dbh->prepare( <<SQL );
SELECT f.asset_id, p.api_id, p.display_name, p.avatar_uri
FROM favorited_by f
JOIN person p ON p.person_id = f.person_id
WHERE f.asset_id IN ($in_sql)
SQL
        $sth->execute( @ids );
        while ( my $row = $sth->fetchrow_hashref ) {
            my $asset_id = delete $row->{asset_id};
            my $idx = $id2idx{ $asset_id };
            push @{ $assets[ $idx ]{favorited_by} }, $row;
        }
        $sth->finish;
    }

    return \@assets;
}

sub process_tt {
    my( $env, $tmpl, $stash ) = @_;

    $stash->{param} ||= $env->{QUERY_STRING} ?
        CGI::Deurl::XS::parse_query_string( $env->{QUERY_STRING} ) :
        {};

    $tt->process( $tmpl, $stash, \my( $out ) )
        or return error( 500, $tt->error );
    Encode::_utf8_off( $out );

    return [
        200,
        [ 'Content-Type', 'text/html' ],
        [ $out ],
    ];
}

my $leaders = sub {
    my $env = shift;

    # The client can ask for a specific day's worth of favorites by
    # specifying the /YYYY-MM-DD in the path; we default to the current day.
    my $start;
    if ( $env->{PATH_INFO} &&
         $env->{PATH_INFO} =~ /^\/(\d{4})\-(\d{2})\-(\d{2})$/ ) {
        $start = DateTime->new( year => $1, month => $2, day => $3 );
    } else {
        $start = DateTime->now->truncate( to => 'day' );
    }
    my $end = $start->clone->add( days => 1 );

    my $assets = load_assets_by( <<SQL, $start->ymd, $end->ymd );
WHERE a.favorite_count > 0 AND a.created BETWEEN ? AND ? ORDER BY a.favorite_count DESC LIMIT 20
SQL

    return process_tt( $env, 'assets.tt', {
        assets      => $assets,
        body_class  => 'leaders',
    } );
};

my $dashboard = sub {
    my $env = shift;

    my $assets = load_assets_by( <<SQL );
JOIN stream s ON s.asset_id = a.asset_id
WHERE s.person_id = 1
ORDER BY a.created DESC LIMIT 20
SQL

    return process_tt( $env, 'assets.tt', {
        assets      => $assets,
        body_class  => 'dashboard',
    } );
};

builder {
    mount '/css' => builder {
        Plack::App::File->new( { root => './css' } );
    };
    
    mount '/img' => builder {
        Plack::App::File->new( { root => './img' } );
    };
    
    mount '/js' => builder {
        Plack::App::File->new( { root => './js' } );
    };
    
    mount '/facebox' => builder {
        Plack::App::File->new( { root => './facebox' } );
    };

    mount '/' => $dashboard;
    mount '/most' => $leaders;
    mount '/favicon.ico' => sub { return $error->( 404, "not found" ) };
};