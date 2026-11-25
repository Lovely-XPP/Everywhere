"""Map rendering coordinates. Stored points and transmitted points are always WGS 84."""
import math


def project(lat,lon,z):
    scale=256*(2**z)
    rad=math.radians(max(-85.05112878,min(85.05112878,lat)))
    return (lon+180)/360*scale,(1-math.asinh(math.tan(rad))/math.pi)/2*scale


def unproject(x,y,z):
    scale=256*(2**z)
    return math.degrees(math.atan(math.sinh(math.pi*(1-2*max(0,min(1,y/scale)))))),x%scale/scale*360-180


def display(lat,lon,gcj):
    if not gcj or not (.8293<=lat<=55.8271 and 72.004<=lon<=137.8347):
        return lat,lon
    x,y=lon-105,lat-35
    def wave(v,a,b,c,d):
        return (a*math.sin(v*b*math.pi)+c*math.sin(v*d*math.pi))*2/3
    common=wave(x,20,6,20,2)
    dy=-100+2*x+3*y+.2*y*y+.1*x*y+.2*math.sqrt(abs(x))+common+wave(y,20,1,40,1/3)+wave(y,160,1/12,320,1/30)
    dx=300+x+2*y+.1*x*x+.1*x*y+.1*math.sqrt(abs(x))+common+wave(x,20,1,40,1/3)+wave(x,150,1/12,300,1/30)
    radius,e=6378245,.006693421622965943
    angle=math.radians(lat)
    f=1-e*math.sin(angle)**2
    return lat+math.degrees(dy*f**1.5/(radius*(1-e))),lon+math.degrees(dx*math.sqrt(f)/(radius*math.cos(angle)))


def from_map(lat,lon,gcj):
    a,b=lat,lon
    for _ in range(8):
        y,x=display(a,b,gcj)
        a+=lat-y
        b+=lon-x
        if max(abs(lat-y),abs(lon-x))<1e-9: break
    return a,b
