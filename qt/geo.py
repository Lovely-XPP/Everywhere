"""Map rendering coordinates. Stored points and transmitted points are always WGS 84."""
import math


def project(lat,lon,z):
    scale=256*(2**z)
    rad=math.radians(max(-85.05112878,min(85.05112878,lat)))
    return (lon+180)/360*scale,(1-math.asinh(math.tan(rad))/math.pi)/2*scale


def unproject(x,y,z):
    scale=256*(2**z)
    return math.degrees(math.atan(math.sinh(math.pi*(1-2*max(0,min(1,y/scale)))))),x%scale/scale*360-180
