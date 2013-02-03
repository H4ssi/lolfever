# LoLfever - random meta ftw
# Copyright (C) 2013  Florian Hassanen
# 
# This program is free software: you can redistribute it and/or modify
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

use Modern::Perl;

use Mojolicious::Lite;
use Method::Signatures::Simple;

use URI;
use Web::Scraper;
use Data::Dumper;

app->secret('asdfp421c4 1r_');

func parse_role($role) {
    if( $role =~ /mid/xmsi ) {
        return 'mid';     
    } elsif ( $role =~ /top/xmsi ) {
        return 'top';
    } elsif ( $role =~ /supp/xmsi ) {
        return 'support';
    } elsif ( $role =~ /ad|bot/xmsi ) {
        return 'adcarry';
    } elsif ( $role =~ /jungl/xmsi ) {
        return 'jungle';
    } else {
        return;
    }
}

get '/updatedb' => method {
    my $champion_list_scraper = scraper {
        process '.champion-list tr', 'champions[]' => scraper {
            process '.champion-list-icon > a', href => '@href';
            process '//td[last()-1]', role => '@data-sortval';
        };
    };

    my $champion_guide_scraper = scraper {
        process "#guides-champion-list > .big-champion-icon", 'champions[]' => { name => '@data-name', m0 => '@data-meta', map { ( "m$_" => "\@data-meta$_" ) } (1..5) };
    };

    my %db;
    my @errors;

    my $champions = $champion_list_scraper->scrape( URI->new('http://www.lolking.net/champions') );

    for my $c ( @{ $champions->{'champions'} } ) {
        if( defined $c->{'href'} ) {
            unless( $c->{'href'} =~ / ( [^\/]*? ) \z/xms ) {
                push @errors, 'Could not parse champion name from: '.($c->{'href'});
            } else {
                my $name = $1;
                $name = 'wukong' if $name eq 'monkeyking';

                my %roles;
                $db{$name} = \%roles;

                unless( defined $c->{'role'} ) {
                    push @errors, "No role found for champion $name";
                } else {
                    my $r = parse_role($c->{'role'});
                    
                    unless( defined $r ) {
                        push @errors, "Do not know what role this is: ".($c->{'role'});
                    } else {
                        $roles{$r} = 1;
                    }
                }
            }
        }
        
    }

    my $champion_guides = $champion_guide_scraper->scrape( URI->new('http://www.lolking.net/guides') );

    for my $c ( @{ $champion_guides->{'champions'} } ) {
        my @roles = grep { defined && /\w/xms } @$c{ qw<m0 m1 m2 m3 m4 m5> };

        (my $name = $c->{'name'}) =~ s/[^a-zA-Z]//xmsg;

        unless( defined $db{$name} ) {
            push @errors, "No such champion: $name/".($c->{'name'});
        } else {
            for my $role (@roles) {
                my $r = parse_role($role);

                unless( defined $r ) {
                    push @errors, "Do not know what role this is again: $role";
                } else {
                    $db{$name}->{$r} = 1;
                }
            }
        }
    }

    open(my $f, '>', 'champions.db');

    while( my ($name, $roles) = each %db ) {
        for my $role ( keys %$roles ) {
            say {$f} "$name:$role";
        }
    }

    close $f;

    $self->render( text => Dumper({ errors => \@errors, db => {%db} }) );
};

app->start;

