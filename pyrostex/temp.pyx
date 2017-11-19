# cython: infer_types=True, boundscheck=False, nonecheck=False, language_level=3

"""
Handles generation of temperature map from height map
"""

include "macro.pxi"

# imports from packages
from libc.math cimport exp, cos, log2

import png
import numpy as np

cimport numpy as np

# imports from within project
from .map cimport CubeMap, lat_lon_from_vector_


DEF ATM_M = 0.029  # molar mass of atmosphere
DEF R = 8.3144598  # gas constant

DEF MAX_T = 8192  # allows 1/8 Kelvin accuracy up to 8,192 K
DEF MAX_MAP_V = 65535
DEF CONVERSION_RATIO = 8.

DEF MEAN_CS = 0.866  # average cross section
DEF BASE_H_VAL = 32767


cdef class TMap(CubeMap):

    cpdef float t_from_lat_lon(self, pos):
        cdef double[2] pos_
        cp2a_2d(pos, pos_)
        return t_from_stored_v(self.v_from_lat_lon_(pos_))

    cdef float t_from_lat_lon_(self, double[2] pos):
        return t_from_stored_v(self.v_from_lat_lon_(pos))

    cpdef float t_from_xy(self, pos):
        cdef double[2] pos_
        cp2a_2d(pos, pos_)
        stored_v = self.v_from_xy_(pos_)
        return t_from_stored_v(stored_v)

    cdef float t_from_xy_(self, double[2] pos):
        stored_v = self.v_from_xy_(pos)
        return t_from_stored_v(stored_v)

    cpdef float t_from_vector(self, vector):
        cdef double[3] vector_
        cp2a_3d(vector, vector_)
        stored_v = self.v_from_vector_(vector_)
        return t_from_stored_v(stored_v)

    cdef float t_from_vector_(self, double[3] vector):
        stored_v = self.v_from_vector_(vector)
        return t_from_stored_v(stored_v)

    cpdef void set_xy_t(self, pos, float t):
        cdef int[2] pos_
        pos_[0] = pos[0]
        pos_[1] = pos[1]
        stored_v = stored_v_from_t(t)
        self.set_xy_(pos_, stored_v)

    cdef void set_xy_t_(self, int[2] pos, float t):
        stored_v = stored_v_from_t(t)
        self.set_xy_(pos, stored_v)

    cpdef void write_png(self, out):
        """
        Writes map as a png to the passed path.
        :param out: path String
        :return: None
        """
        max = 64
        if '.' not in out:
            out += '.png'  # adjust out path
        while True:
            # try to get array to print. if a value is outside range,
            # start over and increase max.
            # this lets us see a map that is scaled to fit the t range
            # of a planet.

            out_arr = np.empty_like(self._arr, np.uint8)
            for y, row in enumerate(self._arr):
                for x, v in enumerate(row):
                    if v > max:
                        # increase max
                        # max *= int(log2(v / max)) + 1
                        while max < v:
                            max *= 2
                        continue  # restart
                    out_arr[y][x] = int(v * 255 / max)
            break  # if array was successfully finished

        with open(out, 'wb') as f:
            height = len(out_arr)
            width = len(out_arr[0])
            w = png.Writer(width, height, greyscale=True)
            w.write(f, out_arr)

cpdef TMap make_warming_map(
        HeightCubeMap height_map,
        float rel_res,  # relative resolution
        float mean_temp,
        float base_atm,
        float atm_warming,
        float base_gravity,
        float radius):
    """
    Creates warming map from height map.
    This map approximates the amount of heat imparted to the atmosphere
    at any given position.
    """
    cdef int x, y
    cdef double[2] xy_pos
    cdef double[2] src_xy
    cdef double[2] lat_lon
    cdef int[2] xy_int_pos
    cdef float t

    cdef int width = int(height_map.width * rel_res)
    cdef int height = int(height_map.height * rel_res)
    cdef TMap warming_map = TMap(
        width=width,
        height=height,
        data_type=np.uint16)

    no_atm_temp = mean_temp - atm_warming # temp at mean lat in w/o atmosphere
    if not 0 <= no_atm_temp <= MAX_T:
        assert False, no_atm_temp  # sanity check
    for x in range(width):
        xy_pos[0] = x
        xy_int_pos[0] = x
        src_xy[0] = xy_pos[0] / width * height_map.width
        for y in range(height):
            # get lat of position
            xy_pos[1] = y
            xy_int_pos[1] = y
            src_xy[1] = xy_pos[1] / height * height_map.height

            h = height_map.v_from_xy_(src_xy) - BASE_H_VAL
            height_map.lat_lon_from_xy_(lat_lon, src_xy)
            # calculate temperature for position as it would be without atm
            t = find_cs_ratio(lat_lon[0]) * no_atm_temp
            if not 0 <= t <= MAX_T:
                assert False, t  # sanity check
            # apply effects of elevation
            # if base_atm > 0:
            #     p = find_pressure(h, base_atm, t, base_gravity)
            #     t += ((p / base_atm) * 2 - 1) * atm_warming
            if not 0 <= t <= MAX_T:
                assert False, (t, base_atm)  # sanity check
            warming_map.set_xy_t_(xy_int_pos, int(t))

    return warming_map

cdef inline float find_pressure(float h, float pb, float tb, float g):
    """
    Calculates pressure at a given point
    :param h: elevation above base (~sea level)
    :param pb: pressure at base elevation
    :param tb: temperature at base elevation
    :param g: gravities at surface
    """
    return pb * exp((-g * ATM_M * h) / (R * tb))


cdef inline float find_cs_ratio(double lat):
    """
    Finds relative cross section compared to mean latitude (30 deg)
    :param lat: double; latitude in radians
    """
    return cos(lat) / MEAN_CS  # get ratio relative to average cs


cdef inline float t_from_stored_v(int stored_v):
    return float(stored_v) / CONVERSION_RATIO


cdef inline int stored_v_from_t(float t):
    return int(t * CONVERSION_RATIO)
