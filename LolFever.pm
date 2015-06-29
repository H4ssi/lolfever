# LoLfever - random meta ftw
# Copyright (C) 2013, 2015  Florian Hassanen
# 
# This file is part of LoLfever.
#
# LoLfever is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package LolFever;

use Modern::Perl '2015';
use feature 'signatures';

use Mojolicious::Lite;

use Mojo::Path;
use Mojo::Pg;
use Mojo::IOLoop;

use Digest;
use Bytes::Random::Secure qw<random_bytes>;
use Crypt::ScryptKDF qw<scrypt_hash scrypt_hash_verify>;

use feature 'postderef';
no warnings 'experimental::postderef';
no warnings 'experimental::smartmatch';
no warnings 'experimental::signatures';

my $config = plugin 'Config';
my $base = $config->{'base'} // '';
my $lol_api_key = $config->{'lol_api_key'};
my $pg = Mojo::Pg->new( $config->{connection_string} );

app->secrets($config->{'secrets'});
random_bytes(32); # get rng seeded (this might block)
my $legacy_sha_salt = $config->{'legacy_sha_salt'};
app->defaults( layout => 'layout' );
app->ua->max_redirects(10);

my @base_path = @{ Mojo::Path->new($base)->leading_slash(0) };
app->hook(before_dispatch => sub ($c) {
  my @base = splice @{ $c->req->url->path->leading_slash(0) }, 0, scalar @base_path;

  $c->rendered(404) unless @base ~~ @base_path;

  push @{ $c->req->url->base->path->trailing_slash(1) }, @base;
});

my %PARSE = ( mid => 'mid', 
              top => 'top',
              support => 'sup',
              adcarry => 'ad|bot',
              jungle => 'jun', );

my @ROLES = keys %PARSE;

sub parse_role( $role_string ) {
    for my $role (@ROLES) {
        return $role if $role_string =~ /$PARSE{$role}/xmsi;
    }
    return;
}

sub pg_setup ( $data, $version, $action ) {
    if ( $data->{schema_version} < $version ) {
        $action->();
        $data->{schema_version} = $version;
        $pg->db->query('update meta set data = ?::jsonb', { json => $data });
    }
}

sub pg_init() {
    $pg->db->query('create table if not exists meta (id integer primary key check (id = 0), data jsonb)');
    my $data = $pg->db->query('select data from meta')->expand->arrays->first;
    unless ($data) {
        $data = [{ schema_version => 0 }];
        $pg->db->query('insert into meta (id, data) values (0, ?::jsonb)', { json => $data->[0] });        
    }
    $data = $data->[0];

    pg_setup($data, 1, sub {
        $pg->db->query('create table champion (id integer primary key, key text unique, name text)')
    });
    pg_setup($data, 2, sub {
        $pg->db->query('alter table champion alter key set not null');
        $pg->db->query('alter table champion alter name set not null');
    });
    pg_setup($data, 3, sub {
        $pg->db->query("alter table champion add free boolean not null default 'f'");
    });
    pg_setup($data, 4, sub {
        $pg->db->query("alter table champion add roles jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 5, sub {
        $pg->db->query("alter table champion add blacklist jsonb not null default '{}'::jsonb, add whitelist jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 6, sub {
        $pg->db->query('create table summoner (id serial primary key, name text unique not null, pw text not null, pwhash text)');
    });
    pg_setup($data, 7, sub {
        $pg->db->query("alter table summoner add roles jsonb not null default '{}'::jsonb");
    });
    pg_setup($data, 8, sub {
        $pg->db->query("alter table summoner add champions jsonb not null default '{}'::jsonb");
    });
}

sub store_champs( $champs, $cb ) {
    my $h = $pg->db;
    my $tx = $h->begin;

    my $handler = sub ($c) {
        return sub ($d, @) {
                my $cb = $d->begin;
                $h->query('update champion set (key, name, free, roles) = (?, ?, ?, ?::jsonb) where id = ? returning id',
                    $c->{key}, $c->{name}, $c->{free} ? 't' : 'f', { json => $c->{roles} }, $c->{id},
                    sub ($, $, $r) {
                        if ($r->arrays->size) {
                            $cb->();
                        } else {
                            $h->query('insert into champion (id, key, name, free, roles) values (?, ?, ?, ?, ?::jsonb)',
                                $c->{id}, $c->{key}, $c->{name}, $c->{free} ? 't' : 'f', { json => $c->{roles} },
                                $cb);
                        }
                    });
        }
    };

    Mojo::IOLoop->delay(
        (map { $handler->($_) } (values %$champs)),
        sub (@) {
            $tx->commit;
            $cb->(undef);
        });
}

sub get_champs() {
    return $pg->db->query('select * from champion order by name')->expand->hashes;
}

sub alter_anylist( $champ_key, $role, $list_name, $op ) {
    $pg->db->query("update champion
                    set $list_name = (select coalesce(json_object_agg(key, value), '{}')::jsonb
                                      from (select * from jsonb_each($list_name)
                                            $op
                                            select ?, 'null'::jsonb) i)
                    where key = ?", $role, $champ_key);
}

sub add_blacklist( $champ_key, $role ) {
    alter_anylist( $champ_key, $role, 'blacklist', 'union' );
}

sub add_whitelist( $champ_key, $role ) {
    alter_anylist( $champ_key, $role, 'whitelist', 'union' );
}

sub remove_blacklist( $champ_key, $role ) {
    alter_anylist( $champ_key, $role, 'blacklist', 'except' );
}

sub remove_whitelist( $champ_key, $role ) {
    alter_anylist( $champ_key, $role, 'whitelist', 'except' );
}

sub save_user( $user ) {
    $pg->db->query("update summoner set (pw, pwhash, roles, champions) = (?, ?, ?::jsonb, ?::jsonb) where name = ?",
        $user->{pw}, $user->{pwhash}, {json => $user->{roles}}, {json => $user->{champions}}, $user->{name});
}

sub get_users() {
    return $pg->db->query('select * from summoner order by name')->expand->hashes;
}

sub get_user( $name ) {
    return $pg->db->query('select * from summoner where name = ?', $name)->expand->hashes->first;
}

sub write_db( $file, $data ) {
    open(my $f, '>', $file);

    for my $key ( sort keys %$data ) {
        for my $value ( sort keys %{ $data->{$key} } ) {
            say {$f} "$key:$value" if $data->{$key}->{$value};
        }
    }

    close $f;
}

sub read_db( $file ) {
    open(my $f, '<', $file);

    my %data;

    while(my $l = <$f>) {
        chomp $l;

        next if $l =~ /\A \s* \z/xms;

        my ($key,$val) = split /:/xms, $l, 2;

        $data{$key} = {} unless defined $data{$key};

        $data{$key}->{$val} = 1;
    }

    close $f;

    return \%data;
}

post("/championdb" => sub ($c) {
    my @errors;

    $c->render_later;
    $c->delay(
        sub ($d) {
            $c->ua->get("https://euw.api.pvp.net/api/lol/euw/v1.2/champion?api_key=$lol_api_key" => $d->begin);
            $c->ua->get("https://global.api.pvp.net/api/lol/static-data/euw/v1.2/champion?dataById=true&api_key=$lol_api_key" => $d->begin);
            $c->ua->get('http://www.lolking.net/champions' => $d->begin);
            $c->ua->get('http://www.lolking.net/guides' => $d->begin);
            $c->ua->get('http://www.lolpro.com' => $d->begin);
        },
        sub ($d, $champions_tx, $static_tx, $champs_tx, $guides_tx, $roles_tx) {

            my $champions = $champions_tx->res->json->{'champions'};
            my $static = $static_tx->res->json->{'data'};

            my $ids = { map { (lc $_->{key}) => $_->{id} } (values %$static) };
            my $champs = { map { $_->{id} => { id => $_->{id},
                                               key => lc $static->{$_->{id}}{key},
                                               name => $static->{$_->{id}}{name},
                                               free => !!$_->{freeToPlay},
                                               roles => {},} } @$champions };

            my $db = { map { (lc $static->{$_->{id}}->{key}) => {} } @$champions };
            my $free = { map { (lc $static->{$_->{id}}->{key}) => { free => 1 } } (grep { $_->{freeToPlay} } @$champions) }; 

            for my $champ ( $champs_tx->res->dom->find('.champion-list tr')->@* ) {
                my $a = $champ->at('.champion-list-icon > a');
                if( defined $a ) {
                    unless( $a->attr('href') =~ / ( [^\/]*? ) \z/xms ) {
                        push @errors, 'Could not parse champion name from: '.($a->attr('href'));
                    } else {
                        my $key = $1;

                        unless( exists $ids->{$key} ) {
                            push @errors, "What is this champion: $key";
                        } else {
                            my $role = $champ->at('td:nth-last-of-type(2)');
                            unless( defined $role && defined $role->attr('data-sortval') ) {
                                push @errors, "No role found for champion $key";
                            } else {
                                my $r = parse_role($role->attr('data-sortval'));
                                
                                unless( defined $r ) {
                                    push @errors, "Do not know what role this is: '".($role->attr('data-sortval'))."' (champion is '$key')";
                                } else {
                                    $db->{$key}->{$r} = 1;
                                    $champs->{$ids->{$key}}{roles}{$r} = undef;
                                }
                            }
                        }
                    }
                }
            }

            for my $champ ( $guides_tx->res->dom->find('#guides-champion-list > .big-champion-icon')->@* ) {
                my ($key) = $champ->attr('href') =~ /champion=([a-z]*)/xms;
                my @roles = map { $champ->attr("data-meta$_") } @{['', 1..5]};
         
                unless( exists $ids->{$key} ) {
                    push @errors, "No such champion: $key";
                } else {
                    for my $role (@roles) {
                        next unless defined $role;
                        next unless $role =~ /\w/xms;

                        my $r = parse_role($role);

                        unless( $r ) {
                            push @errors, "Do not know what role this is again: '$role' (champion is '$key')";
                        } else {
                            $db->{$key}->{$r} = 1;
                            $champs->{$ids->{$key}}{roles}{$r} = undef;
                        }
                    }
                }
            }

            for my $champ ( $roles_tx->res->dom->find('li.game-champion')->@* ) {
                my @classes = split /\s+/xms, $champ->attr('class');

                my ($key_info) = grep { /\A game-champion-/xms && !/\A game-champion-tag-/xms } @classes;

                if( $key_info =~ /\A game-champion-(.*) \z/xms ) {
                    my $key = $1 =~ s/[^a-z]//xmsgr;
                    $key = 'monkeyking' if $key eq 'wukong';

                    unless( exists $ids->{$key} ) {
                        push @errors, "What is this for a champion: $key?";
                    } else {
                        $db->{$key}->{'top'}     = 1 if 'game-champion-tag-top'      ~~ @classes;
                        $db->{$key}->{'mid'}     = 1 if 'game-champion-tag-mid'      ~~ @classes;
                        $db->{$key}->{'adcarry'} = 1 if 'game-champion-tag-duo'      ~~ @classes && !( 'game-champion-tag-support' ~~ @classes );
                        $db->{$key}->{'support'} = 1 if 'game-champion-tag-support'  ~~ @classes;
                        $db->{$key}->{'jungle'}  = 1 if 'game-champion-tag-jungler'  ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'top'}     = undef if 'game-champion-tag-top'      ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'mid'}     = undef if 'game-champion-tag-mid'      ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'adcarry'} = undef if 'game-champion-tag-duo'      ~~ @classes && !( 'game-champion-tag-support' ~~ @classes );
                        $champs->{$ids->{$key}}{roles}{'support'} = undef if 'game-champion-tag-support'  ~~ @classes;
                        $champs->{$ids->{$key}}{roles}{'jungle'}  = undef if 'game-champion-tag-jungler'  ~~ @classes;

                    }
                }
            }

            store_champs($champs, $d->begin);

            write_db('champions.db', $db);
            write_db('free.db', $free);
        },
        sub ($d) {
            $c->render('championdb', errors => ( @errors ? \@errors : undef ), champs => get_champs(), updated => 1, roles => [ sort @ROLES ], mode => 'champions');
        }
    );
})->name('championdb');

sub manage_list( $file, $champion, $role, $listed ) {
    my $list = read_db( $file );

    $list->{ $champion }->{ $role } = $listed;

    write_db( $file, $list );
}

sub manage_blacklist( $champion, $role, $listed ) {
    manage_list( 'blacklist.db', $champion, $role, $listed );
}

sub manage_whitelist( $champion, $role, $listed ) {
    manage_list( 'whitelist.db', $champion, $role, $listed );
}

get ( '/migrate_lists' => sub ($c) {
    my $b = read_db('blacklist.db');
    for my $champ (keys %$b) {
        $champ = "monkeyking" if $champ eq "wukong";
        for my $role (keys $b->{$champ}->%*) {
            add_blacklist( $champ, $role );
        }
    }
    my $w = read_db('whitelist.db');
    for my $champ (keys %$w) {
        $champ = "monkeyking" if $champ eq "wukong";
        for my $role (keys $w->{$champ}->%*) {
            add_whitelist( $champ, $role );
        }
    }

    $c->redirect_to('championdb');
});

get ( '/migrate_users' => sub ($c) {
    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

    my $champs = get_champs();

    my $ids = { map { $_->{key} => $_->{id} } @$champs };

    for my $user (@users) {
        my $u = read_db("$user.db");

        $u->{pw} = (keys $u->{pw}->%*)[0];
        $u->{pwhash} = (keys $u->{pwhash}->%*)[0] if exists $u->{pwhash};
        $u->{champions} = { map { $ids->{$_ eq "wukong" ? "monkeyking" : $_} => undef } (keys $u->{owns}->%*) };
        $u->{roles} = { map { $_ => undef } (keys $u->{can}->%*) };

        $pg->db->query("insert into summoner (name, pw, pwhash, champions, roles) values (?, ?, ?, ?::jsonb, ?::jsonb)",
            $user,
            $u->{pw},
            $u->{pwhash},
            {json => $u->{champions}},
            {json => $u->{roles}});
    }

    $c->redirect_to('home');
});

get( "/champion/:champion/:role/blacklist" => sub ($c) {
    manage_blacklist( $c->param('champion'), $c->param('role'), 1 );
    add_blacklist( $c->param('champion'), $c->param('role') );
    
    $c->redirect_to('championdb');
})->name('blacklist');

get( "/champion/:champion/:role/no_blacklist" => sub ($c) {
    manage_blacklist( $c->param('champion'), $c->param('role'), 0 );
    remove_blacklist( $c->param('champion'), $c->param('role') );
    
    $c->redirect_to('championdb');
})->name('no_blacklist');

get( "/champion/:champion/:role/whitelist" => sub ($c) {
    manage_whitelist( $c->param('champion'), $c->param('role'), 1 );
    add_whitelist( $c->param('champion'), $c->param('role') );
    
    $c->redirect_to('championdb');
})->name('whitelist');

get( "/champion/:champion/:role/no_whitelist" => sub ($c) {
    manage_whitelist( $c->param('champion'), $c->param('role'), 0 );
    remove_whitelist( $c->param('champion'), $c->param('role') );
    
    $c->redirect_to('championdb');
})->name('no_whitelist');

get "/championdb" => sub ($c) {
    $c->render( 'championdb', errors => undef, champs => get_champs(), updated => 0, roles => [ sort @ROLES ], mode => 'champions' );
};

get("/user/:name" => sub ($c) {
    my $name = $c->param('name');
    return $c->render( text => "No user" ) unless defined $name;

    my $user = get_user( $name );
    return $c->render( text => "No such user: $name", name => $name, mode => 'profile' ) unless $user;

    my $pw_change_required = !(defined $user->{'pwhash'});

    $c->render($c->param('edit') ? 'user_edit' : 'user', name => $user->{name}, user => $user, champs => get_champs(), roles => [ sort @ROLES ], pw_change_required => $pw_change_required, mode => 'profile' );
})->name('user');

post "/user/:name" => sub ($c) {
    my $name = $c->param('name');
    return $c->render( text => "No user" ) unless defined $name;

    my $user = get_user( $name );
    return $c->render( text => "No such user: $name", name => $name, mode => 'profile' ) unless $user;
    
    return $c->render( text => "User deactivated: $name", name => $name, mode => 'profile' ) unless $user->{pw} || $user->{pwhash};

    my $data = read_db("$name.db");    

    my $pw = $c->param('current_pw');
    my $hash;
    my $pw_change_required = 0;
    my $authenticated = 0;

    if( $user->{pwhash} ) {
        $hash = $user->{pwhash};
    } else {
        $hash = scrypt_hash($user->{pw}, random_bytes(32));
        $pw_change_required = 1;
    }

    if( $hash =~ / \A SCRYPT: /xms ) {
        $authenticated = scrypt_hash_verify( $pw, $hash );  
    } else {
        $authenticated = $hash eq Digest->new('SHA-512')->add($legacy_sha_salt)->add($pw)->b64digest;
    }

    return $c->render( text => 'invalid pw', name => $name, mode => 'profile' ) unless $authenticated;

    return $c->render( text => 'must change pw', name => $name, mode => 'profile' ) if $pw_change_required && !$c->param('new_pw_1');

    if( $c->param('new_pw_1') ) {
        return $c->render( text => 'new pws did not match', name => $name, mode => 'profile' ) unless $c->param('new_pw_1') eq $c->param('new_pw_2');
        
        $user->{pwhash} = scrypt_hash($c->param('new_pw_1'), random_bytes(32));
    } elsif( $hash !~ / \A SCRYPT: /xms ) {
        $user->{pwhash} = scrypt_hash($pw, random_bytes(32));
    }
    
    $data->{can} = { map { $_ => !!$c->param("can:$_") } @ROLES };
    $user->{roles} = { map { $_ => undef } (grep { $c->param("can:$_") } @ROLES) };

    my $champs = get_champs();

    $data->{owns} = { map { $_->{key} => !!$c->param("owns:$_->{key}") } @$champs };
    $user->{champions} = { map { $_->{id} => undef } (grep { $c->param("owns:$_->{key}") } @$champs) };

    write_db("$name.db", $data);
    save_user( $user );

    return $c->redirect_to;
};

sub roll_form($c) {
    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

    return $c->render( 'roll', users => get_users(), roles => [ sort @ROLES ], champs => get_champs(), players => undef, woroles => undef, wochampions => undef, roll => undef, fails => undef, mode => 'roll' );
};

get "" => \&roll_form;
get "/troll" => \&roll_form;

sub select_random( @values ) {
    my $len = scalar  @values;
    my $ran = int(rand($len));

    my @other = grep { $_ != $ran } (0..$len-1);

    return @values[$ran, @other];
}

sub all_options( $db, $user, $tabu_roles, $tabu_champions ) {
    my @tabu_champion_ids = map { $_->{id} } @$tabu_champions;
    return map {
        my $champion = $_;
        if ( ( exists $user->{champions}{$champion->{id}} || $champion->{free} ) && !( $champion->{id} ~~ @tabu_champion_ids ) ) {
            map {
                my $role = $_;
                if ( exists $user->{roles}{$role} && !( $role ~~ @$tabu_roles ) ) {
                    { champion => $champion, role => $role };
                } else { (); }
            } keys $db->{$champion->{id}}{effective_roles}->%*;
        } else { (); }
    } values %$db;
}

sub combine_blacklist_whitelist( $champs ) {
    return { map { 
        my $champ = $_;
        ( $champ->{id} => { 
            %$champ,
            effective_roles => { map {
                my $role = $_;
                if ( ( exists $champ->{roles}{$role} || exists $champ->{whitelist}{$role} ) && !exists $champ->{blacklist}{$role} ) {
                    ( $role => undef );
                } else { 
                    (); 
                } 
            } @ROLES } } );
    } @$champs };
}

sub trollify( $db ) {
    for my $champ ( keys %$db ) {
        my @roles = keys $db->{$champ}{effective_roles}->%*;
        push @roles, 'adcarry', 'support' if 'adcarry' ~~ @roles || 'support' ~~ @roles; # combine bot lane :)
        my @troll_roles = grep { !( $_ ~~ @roles ) } @ROLES;

        $db->{$champ}{effective_roles} = { map { $_ => undef } @troll_roles };
    }

    return $db;
}

sub roll( $c, $trolling = '' ) {
    my @players = grep { $_ } $c->every_param('players')->@*;
    my @woroles = grep { $_ } $c->every_param('woroles')->@*;
    my @wochampionkeys = grep { $_ } $c->every_param('wochampions')->@*;
    
    my %player_specs = map { ( $_ => get_user($_) ) } @players;

    my $champs = get_champs();
    my @wochampions = grep { $_->{key} ~~ @wochampionkeys } @$champs;

    my $db = combine_blacklist_whitelist( $champs );
    $db = trollify( $db ) if $trolling;
    
    my @fails;

    my $TRIES = 42;

    my %roll;
    for (1..$TRIES) {
        undef %roll;
        my @u = @players;

        while( scalar @u ) {
            (my $user, @u) = select_random(@u);

            my @options = all_options($db, $player_specs{$user}, [ @woroles, map { $_->{'role'} } values %roll ], [ @wochampions, map { $_->{champion} } values %roll ]);
            
            unless( scalar @options ) {
                push @fails, { $user => { %roll } };
                last;
            }

            $roll{$user} = $options[ int(rand(scalar @options)) ];
        }

        last if( ( scalar ( keys %roll ) ) == ( scalar @players ) );
    }

    my @users = map { /(.*)\.db\z/xms; $1 } (grep { !/champions|roll|free|blacklist|whitelist/xms } (glob '*.db'));

    return $c->render( 'roll', users => get_users(), roles => [ sort @ROLES ], champs => $champs, players => \@players, woroles => \@woroles, wochampions => \@wochampionkeys, 
                           roll => (scalar keys %roll ? \%roll : undef), fails => (scalar @fails ? $c->dumper(\@fails) : undef), mode => 'roll' );
}

get "/roll" => sub ($c) {
    return $c->redirect_to('home');
};

post("" => sub ($c) {
    return roll($c);
})->name('home');

post("/troll" => sub ($c) {
    return roll($c, 'trolling');
})->name('trollroll');

pg_init();
app->start;

__DATA__

@@ layouts/layout.html.ep
<!DOCTYPE html>
<html>
<!--
  - LoLfever - random meta ftw
  - Copyright (C) 2013, 2015  Florian Hassanen
  - 
  - This file is part of LoLfever.
  -
  - LoLfever is free software: you can redistribute it and/or modify
  - it under the terms of the GNU Affero General Public License as
  - published by the Free Software Foundation, either version 3 of the
  - License, or (at your option) any later version.
  - 
  - This program is distributed in the hope that it will be useful,
  - but WITHOUT ANY WARRANTY; without even the implied warranty of
  - MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  - GNU Affero General Public License for more details.
  - 
  - You should have received a copy of the GNU Affero General Public License
  - along with this program.  If not, see <http://www.gnu.org/licenses/>.
  -->
<head>
<title>LoL Fever</title>
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<link href="<%= url_for '/css/bootstrap.min.css' %>" rel="stylesheet" media="screen">
<link href="<%= url_for '/css/lolfever.css' %>" rel="stylesheet" media="screen">
</head>
<body>
<div class="container">
<nav class="navbar navbar-default">
    <div class="container-fluid">
        <div class="navbar-header">
            <button type="button" class="navbar-toggle collapsed" data-toggle="collapse" data-target="#navbar">
                <span class="sr-only">Toggle navigation</span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
                <span class="icon-bar"></span>
            </button>
            %= link_to LoLfever => 'home', {}, class => 'navbar-brand'
        </div>
        <div class="collapse navbar-collapse" id="navbar">
            <ul class="nav navbar-nav">
                <li <% if( $mode eq 'roll'      ) { %> class="active" <% } %> >
                    %= link_to Roll => 'home'
                </li>
                <li <% if( $mode eq 'champions' ) { %> class="active" <% } %> >
                    %= link_to Champions => 'championdb'          
                </li>
                <% if( $mode eq 'profile' ) { %> 
                    <li class="active">
                        %= link_to ( (stash 'name') . "'" . ( (stash 'name') =~ /s \z/xms ? '' : 's') . ' profile')                
                    </li> 
                <% } %>
            </ul>
        </div>
    </div>
</nav>
<%= content %>
<div style="margin-top: 40px" class="text-center"><small>This is free software. Get the <a href="https://github.com/H4ssi/lolfever">source</a>!</small></div>
</div>
<script src="<%= url_for '/js/jquery.min.js' %>"></script>
<script src="<%= url_for '/js/bootstrap.min.js' %>"></script>
</body>
</html>

@@ roll.html.ep

% if( defined $roll ) {
    <dl class="well well-sm dl-horizontal">
    % for my $player ( sort keys %$roll ) {
        <dt><%= $player %></dt><dd><%= $roll->{$player}{champion}{name} %> (<%= $roll->{$player}{role} %>)</dd>
    % }
    </dl>
% }

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group">
    <label>Players</label>
    % for my $user (@$users) {
        <div class="checkbox">
            <label>
                %= input_tag "players", type => 'checkbox', value => $user->{name}, $user->{name} ~~ @$players ? ( checked => 'checked' ) : ()
                %= link_to $user->{name} => 'user' => { name => $user->{name} }
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Excluded roles</label>
    % for my $role (@$roles) {
        <div class="checkbox">
            <label>
                %= input_tag "woroles", type => 'checkbox', value => $role, $role ~~ @$woroles ? ( checked => 'checked' ) : ()
                %= $role
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Excluded champions</label>
    % for my $i (0..3) {
        <select name="wochampions" class="form-control">
            <option value=""></option>
            % for my $champ (@$champs) {
                <option value="<%= $champ->{key} %>"
                    % if( $champ->{key} eq ($wochampions->[$i] // '') ) {
                        selected="selected"
                    % }
                ><%= $champ->{name} %></option>
            % }
        </select>
    % }
</div>

<button type="submit" class="btn btn-default">Roll</button>

% end 
%# of form

% if( defined $fails ) {
    <pre><%= $fails %></pre>
% }


@@ user.html.ep

<h3>Possible roles</h3>
<ul class="list-inline">
% for my $role (@$roles) {
    % if( exists $user->{roles}{$role} ) {
        <li><%= $role %></li>
    % }
% }
</ul>

<h3>Owned champions</h3>
<ul class="list-inline">
% for my $champ (@$champs) {
    % if( exists $user->{champions}{$champ->{id}} ) {
        <li><%= $champ->{name} %></li>
    % }
% }
</ul>

%= link_to Edit => url_for->query(edit => 1) => (class => 'btn btn-default')


@@ user_edit.html.ep

%= form_for url_for() => (method => 'POST') => begin

<div class="form-group">
    <label>Possible roles</label>

    % for my $role (@$roles) {
        <div class="checkbox">    
            <label>
                %= input_tag "can:$role", type => 'checkbox', value => 1, exists $user->{roles}{$role} ? ( checked => 'checked' ) : ()
                <%= $role %>
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Owned champions</label>

    % for my $champ (@$champs) {
        <div class="checkbox">    
            <label>
                %= input_tag "owns:$champ->{key}", type => 'checkbox', value => 1, exists $user->{champions}{$champ->{id}} ? ( checked => 'checked' ) : ()
                <%= $champ->{name} %>
            </label>
        </div>
    % }
</div>

<div class="form-group">
    <label>Authentication</label>

    <div class="form-group">
        <label for="current_pw">
            Current password <strong>(required)</strong>
        </label>
        %= input_tag 'current_pw' => ( type => 'password', placeholder => 'Password', id => 'current_pw', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_1">
            New password 
            % if( $pw_change_required ) {
                <strong>(Password change required!)</strong>
            % } else {
                (Leave empty if you do not want to change your password)
            % }
        </label>
        %= input_tag 'new_pw_1' => ( type => 'password', placeholder => 'Password', id => 'new_pw_1', class => 'form-control' )
    </div>

    <div class="form-group">
        <label for="new_pw_2">
            Retype new password
        </label>
        %= input_tag 'new_pw_2' => ( type => 'password', placeholder => 'Password', id => 'new_pw_2', class => 'form-control' )
    </div>
</div>

<button type="submit" class="btn">Save</button>

% end
%# of form


@@ championdb.html.ep

%= form_for url_for() => (method => 'POST') => begin
    <div class="form-group">
        <button type="submit" class="btn btn-default">Update DB from the Interwebs</button>
        <p class="help-block">You need to do this once per free champion rotation</p>
    </div>
% end

% if( $updated ) {
    % if( defined $errors ) {
        <div class="alert alert-danger" role="alert">
            % for my $error (@$errors) {
                <p><%= $error %></p>
            % }
        </div>
    % } else {
        <div class="alert alert-success" role="alert">
            Champion DB was updated without errors!
        </div>
    % }
% }

<table class="table table-hover table-condensed champion-table"><tbody>
    % for my $champ (@$champs) {
        <tr>
            <th> 
                <%= $champ->{name} %>
                % if( $champ->{free} ) {
                    <span class="label label-info">free</span>
                % }
            </th>
            % for my $role ( @$roles ) {
                <td>
                    % if( exists $champ->{roles}{$role} ) {
                        %= link_to exists $champ->{blacklist}{$role} ? 'no_blacklist' : 'blacklist' => { champion => $champ->{key}, role => $role } => begin
                            % if( exists $champ->{blacklist}{$role} ) {
                                <s><%= $role %></s>
                            % } else {
                                <%= $role %>
                            % }
                        % end
                    % } else {
                        %= link_to exists $champ->{whitelist}{$role} ? 'no_whitelist' : 'whitelist' => { champion => $champ->{key}, role => $role } => begin
                            % if( exists $champ->{whitelist}{$role} ) {
                                <u><%= $role %></u>
                            % } else {
                                <span class="non-role"><%= $role %></span>
                            % }
                        % end
                    % }
                </td>
            % }
        </tr>
    % }
</tbody></table>
