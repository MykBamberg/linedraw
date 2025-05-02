/*
Copyright (C) 2025  Mykolas Bamberg

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

module linedraw;

import std.math;
import std.array;
import std.range;
import std.algorithm;
import std.stdio;
import std.typecons;
import std.algorithm.mutation;
import std.parallelism;
import fast_noise;

struct Point {
    int x, y;

    Point opBinary(string op)(Point rhs) const if (op == "+") {
        return Point(x + rhs.x, y + rhs.y);
    }
}

private struct Pointf {
    float x, y;

    Pointf opBinary(string op)(Pointf rhs) const if (op == "+") {
        return Pointf(x + rhs.x, y + rhs.y);
    }

    Pointf opBinary(string op)(float scalar) const if (op == "*") {
        return Pointf(x * scalar, y * scalar);
    }
}

private bool[][] sobelFilter(int delegate(int x, int y) getPixelBrightness, int w, int h) {
    bool[][] output = new bool[][](h, w);

    foreach (x; parallel(iota(0, w))) {
        foreach (y; 0..h) {
            int px =
               -1 * getPixelBrightness(x - 1, y - 1) +
                1 * getPixelBrightness(x + 1, y - 1) +
               -2 * getPixelBrightness(x - 1, y    ) +
                2 * getPixelBrightness(x + 1, y    ) +
               -1 * getPixelBrightness(x - 1, y + 1) +
                1 * getPixelBrightness(x + 1, y + 1);

            int py =
               -1 * getPixelBrightness(x - 1, y - 1) +
               -2 * getPixelBrightness(x    , y - 1) +
               -1 * getPixelBrightness(x + 1, y - 1) +
                1 * getPixelBrightness(x - 1, y + 1) +
                2 * getPixelBrightness(x    , y + 1) +
                1 * getPixelBrightness(x + 1, y + 1);

            output[y][x] = (px * px) + (py * py) > 128 * 128;
        }
    }

    return output;
}

private pure nothrow int[][] getDots(string dir)(bool[][] edges) {
    static if (dir == "V") {
        int outer = cast(int)edges.length;
        int inner = cast(int)edges[0].length;
        alias getPix = (int x, int y) => edges[y][x];
    } else static if (dir == "H") {
        int outer = cast(int)edges[0].length;
        int inner = cast(int)edges.length;
        alias getPix = (int x, int y) => edges[x][y];
    }

    int count = 0;
    int[][] dots;
    foreach (y; 0..outer) {
        int[] row;
        for (int x = 1; x < inner; x++) {
            if (getPix(x, y)) {
                int x0 = x;
                while (x < inner && getPix(x, y)) x++;
                row ~= (x + x0) / 2;
                count++;
            }
        }
        dots ~= row;
    }
    return dots;
}

private pure nothrow Point[][] connectDots(string dir)(int[][] dots, int maxCoord) {
    static if (dir == "V") {
        alias translate = (int coord, int row) => Point(coord, row);
        alias getCoord = (Point p) => p.x;
        alias getRow = (Point p) => p.y;
    } else static if (dir == "H") {
        alias translate = (int coord, int row) => Point(row, coord);
        alias getCoord = (Point p) => p.y;
        alias getRow = (Point p) => p.x;
    }

    Point[][] contours = dots[0].map!(coord => [translate(coord, 0)]).array;

    size_t[] lastIndecies = new size_t[](maxCoord);
    lastIndecies.fill(size_t.max);

    foreach (row; 1..cast(int)dots.length) {
        size_t[] newIndecies = new size_t[](maxCoord);
        newIndecies.fill(size_t.max);
        foreach (i; 0..dots[row].length) {
            int coord = dots[row][i];

            int closest = -1;
            int closestDist = int.max;
            foreach (prevCoord; dots[row-1]) {
                int dist = (coord - prevCoord).abs;
                if (dist < closestDist) {
                    closest = prevCoord;
                    closestDist = dist;
                }
            }

            if (closestDist <= 3 && lastIndecies[closest] != size_t.max) {
                size_t index = lastIndecies[closest];
                contours[index] ~= translate(coord, row);
                newIndecies[coord] = index;
            } else {
                contours ~= [translate(coord, row)];
                newIndecies[coord] = contours.length - 1;
            }
        }
        lastIndecies = newIndecies;
    }
    return contours;
}

private class PathTerminalGrid {
    struct Terminal {
        Point p;
        size_t index;
        bool isEnd;
        enum invalid = Terminal(Point(0, 0), size_t.max, false);
    }

    private int radius;
    private Terminal[][Point] map;

    this(int maxX, int maxY, int radius) {
        this.radius = radius;
    }

    void insert(size_t i, in Point[] path) {
        insert(i, path[0], false);
        insert(i, path[$-1], true);
    }

    void insert(size_t index, Point p, bool isLastPoint) {
        Point cell = Point(p.x / radius, p.y / radius);
        if ((cell in map) !is null) {
            map[cell] ~= Terminal(p, index, isLastPoint);
        } else {
            map[cell] = [Terminal(p, index, isLastPoint)];
        }
    }

    Terminal popClosest(Point p, size_t excludeIndex = size_t.max) {
        alias dist = (Point a) => hypot(cast(float)(a.x - p.x), cast(float)(a.y - p.y));

        float closestDist = float.max;
        Point closestKey;
        size_t closestIndex;

        Point tlKey = Point(p.x / radius - 1, p.y / radius - 1);

        foreach (tKey; [tlKey, tlKey + Point(0, 1), tlKey + Point(0, 2)]) {
            foreach (key; [tKey, tKey + Point(1, 0), tKey + Point(2, 0)]) {
                if ((key in map) !is null) {
                    foreach(i, t; map[key]) {
                        if (t.index != excludeIndex && dist(t.p) < closestDist) {
                            closestDist = dist(t.p);
                            closestKey = key;
                            closestIndex = i;
                        }
                    }
                }
            }
        }

        if (closestDist <= cast(float)radius) {
            Terminal result = map[closestKey][closestIndex];
            map[closestKey][closestIndex].p = Point(int.min, int.min);
            return result;
        }

        return Terminal.invalid;
    }
}

private Point[][] getContours(int delegate(int x, int y) getPixelBrightness, int w, int h, int strokeScale) {
    bool[][] edges = sobelFilter(getPixelBrightness, w, h);

    auto connectDotsHTask = task((bool[][] e, int h) => connectDots!"H"(getDots!"H"(e), h), edges, h);
    auto connectDotsVTask = task((bool[][] e, int w) => connectDots!"V"(getDots!"V"(e), w), edges, w);
    connectDotsVTask.executeInNewThread();
    connectDotsHTask.executeInNewThread();
    Point[][] contours = connectDotsHTask.yieldForce ~ connectDotsVTask.yieldForce;

    PathTerminalGrid grid = new PathTerminalGrid(w, h, strokeScale);

    foreach (i, ref contour; contours) {
        auto closest = grid.popClosest(contour[0], i);
        if (closest == PathTerminalGrid.Terminal.invalid) {
            grid.insert(i, contour);
            continue;
        }

        if (closest.isEnd) {
            contours[closest.index] ~= contour;
            grid.insert(closest.index, contour[$-1], true);
        } else {
            contours[closest.index] = reverse(contour) ~ contours[closest.index];
            grid.insert(closest.index, contour[0], false);
        }

        contour = null;
    }

    return contours
        .remove!(a => a is null || a.length <= strokeScale)
        .map!((contour) {
            Point averagePoints(Point[] points) {
                Point sum = Point(0, 0);
                foreach (point; points) {
                    sum.x += point.x;
                    sum.y += point.y;
                }
                return Point(sum.x / cast(int)points.length, sum.y / cast(int)points.length);
            }

            return contour.chunks(strokeScale).map!(chunk => averagePoints(chunk)).array;
        }).array;
}

private Point[][] hatch(bool diagonal, int threshold, bool offset)(
    int delegate(int x, int y) getPixelBrightness, int w, int h, int hatchScale
) {
    static if (diagonal) {
        alias resetCondition = (Point p) => p.y < 0 || p.x >= w;
        Nullable!Point getResetPosition (Point last) {
            Point p = last;
            p.y += hatchScale;
            if (p.y >= h) {
                p.x += p.y - (h - 1);
                p.y = h - 1;
            }
            return p.x < w ? Nullable!Point(p) : Nullable!Point.init;
        }
    } else {
        alias resetCondition = (Point p) => p.x >= w;
        Nullable!Point getResetPosition (Point last) {
            Point p = last;
            p.y += hatchScale;
            return p.y < h ? Nullable!Point(p) : Nullable!Point.init;
        }
    }

    Point[][] lines;

    Point p = Point(0, offset ? hatchScale / 2 : 0);
    Nullable!Point resetPosition = Nullable!Point(p);
    do {
        p = resetPosition.get();

        bool trace = false;
        while (!resetCondition(p)) {
            if (getPixelBrightness(p.x, p.y) <= threshold) {
                if (trace) {
                    lines[$-1] ~= p;
                } else {
                    lines ~= [p];
                    trace = true;
                }
            } else {
                trace = false;
            }
            p.x += hatchScale;
            static if (diagonal) {
                p.y -= hatchScale;
            }
        }
        resetPosition = getResetPosition(resetPosition.get());
    } while (!resetPosition.isNull);

    return lines.remove!(a => a.length <= 1);
}

private Point[][] getHatch(int delegate(int x, int y) getPixelBrightness, int w, int h, int hatchScale) {
    return
        hatch!(false, 144, false)(getPixelBrightness, w, h, hatchScale) ~
        hatch!(false, 64, true)(getPixelBrightness, w, h, hatchScale) ~
        hatch!(true, 16, false)(getPixelBrightness, w, h, hatchScale);
}

private void addNoise(ref Pointf[][] paths, float noiseScale) {
    FNLState noise = fnlCreateState();
    noise.noise_type = FNLNoiseType.FNL_NOISE_PERLIN;

    alias perlinNoise = (float a, float b) => Pointf(fnlGetNoise2D(&noise, a, b), fnlGetNoise2D(&noise, -a, -b));

    foreach (i, ref path; paths) {
        float len = path.length * 7.0f + i * 11.0f;
        Pointf last = path[0];
        foreach (j, ref p; path) {
            len += hypot(p.x - last.x, p.y - last.y);
            last = p;
            p = p + perlinNoise(i * 100.0f, len) * noiseScale;
        }
    }
}

private pure nothrow void sortPaths(ref Pointf[][] paths) {
    alias distancePoints = (Pointf p0, Pointf p1) => abs(p0.x - p1.x) + abs(p0.y - p1.y);
    alias distance = (Pointf p, Pointf[] path) => min(distancePoints(p, path[0]), distancePoints(p, path[$-1]));

    if (paths.length == 0) return;

    foreach (i; 0..paths.length - 1) {
        size_t closestPathIndex;
        float closestDistance = float.max;
        foreach(j; i + 1..paths.length) {
            float currentDistance = distance(paths[i][$-1], paths[j]);
            if (currentDistance < closestDistance) {
                closestDistance = currentDistance;
                closestPathIndex = j;
            }
        }

        swap(paths[i + 1], paths[closestPathIndex]);
        if (distancePoints(paths[i][$-1], paths[i + 1][0]) > distancePoints(paths[i][$-1], paths[i + 1][$-1])) {
            paths[i + 1] = reverse(paths[i + 1]);
        }
    }
}

@nogc private pure nothrow bool angleLargerThan(float minAngle)(Pointf p1, Pointf p2, Pointf p3) {
    static assert(minAngle > PI / 2);
    enum float minAngleCos = cos(minAngle);

    float dx1 = p1.x - p2.x;
    float dy1 = p1.y - p2.y;
    float dx2 = p3.x - p2.x;
    float dy2 = p3.y - p2.y;

    float dot = dx1 * dx2 + dy1 * dy2;
    float len1 = dx1 * dx1 + dy1 * dy1;
    float len2 = dx2 * dx2 + dy2 * dy2;

    if (dot >= 0) {
        return false;
    }

    return dot * dot > minAngleCos * minAngleCos * len1 * len2;
}

private void removeShallowVertices(ref Pointf[][] paths) {
    foreach (ref path; parallel(paths)) {
        if (path.length <= 1) {
            continue;
        }

        Pointf[] newPath = [path[0]];
        foreach (i; 1..path.length - 1) {
            if (!angleLargerThan!(0.995 * PI)(newPath[$-1], path[i], path[i + 1])) {
                newPath ~= path[i];
            }
        }
        newPath ~= path[$-1];
        path = newPath;
    }
}

Pointf[][] linedraw(ubyte[] image, int w, int h, int contourDetail, int hatchScale, float noiseScale, bool optimizeRoute) {
    Point[][] output;

    alias pixel = (int x, int y) => image[3 * (x + y * w)..3 * (x + y * w) + 3];

    alias getPixelBrightness = (int x, int y) {
        x = clamp(x, 0, w - 1);
        y = clamp(y, 0, h - 1);
        ubyte[] p = pixel(x, y);
        return (13_926 * p[0] + 46_884 * p[1] + 4725 * p[2]) >> 16;
    };

    if (contourDetail != 0) {
        output ~= getContours(getPixelBrightness, w, h, contourDetail);
    }

    if (hatchScale != 0) {
        output ~= getHatch(getPixelBrightness, w, h, hatchScale);
    }

    Pointf[][] outputf = output.map!((path) => path.map!((p) => Pointf(p.x, p.y)).array).array;

    if (noiseScale > 0f) {
        addNoise(outputf, noiseScale);
    }

    if (optimizeRoute) {
        sortPaths(outputf);
        removeShallowVertices(outputf);
    }

    return outputf;
}
