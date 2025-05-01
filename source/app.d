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

import std.stdio;
import std.getopt;
import std;
import imagefmt;
import linedraw : linedraw;

void main(string[] args) {
    string inputFilePath = null;
    string outputFilePath = null;
    int contourDetail = 8;
    int hatchScale = 8;
    float noiseScale = 3f;
    int strokeWidth = 0;
    bool optimizeRoute = false;

    args = args[0..$];

    try {
        auto helpInformation = getopt(
            args,
            "c|contour", "Contour detail, 0 to disable", &contourDetail,
            "s|hatch", "Hatch scale, 0 to disable", &hatchScale,
            "n|noise", "Noise scale, 0 to disable", &noiseScale,
            "w|width", "Stroke width", &strokeWidth,
            "o|optimize", "Optimize Route", &optimizeRoute
        );

        if (args.length == 3) {
            inputFilePath = args[1] == "-" ? "/dev/stdin" : args[1];
            outputFilePath = args[2] == "-" ? "/dev/stdout" : args[2];
        }

        if (helpInformation.helpWanted || outputFilePath == null || inputFilePath == null) {
            defaultGetoptPrinter(
                format(
                    "Usage:\n    %s [\x1b[4mOPTION\x1b[0m]... \x1b[4mINPUT\x1b[0m \x1b[4mOUTPUT\x1b[0m\n\nArguments:",
                    args[0]
                ), helpInformation.options
            );

            return;
        }

        if (strokeWidth == 0) {
            strokeWidth = max(min(hatchScale, contourDetail) / 3, 1);
        }
    } catch (Exception e) {
        stderr.writefln("Failure parsing arguments\nTry '%s --help' for more information.", args[0]);
        return;
    }

    auto input = read_image(inputFilePath, 3);
    if (input.e) {
        stderr.writefln("Image load error: %s", IF_ERROR[input.e].ptr);
        return;
    }

    scope(exit) input.free();

    auto paths = linedraw(
        input.buf8, input.w, input.h,
        contourDetail, hatchScale, noiseScale, optimizeRoute
    );

    try {
        auto svgFile = File(outputFilePath, "w");
        scope(exit) svgFile.close();
        svgFile.writefln(
            "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"%dpx\" height=\"%dpx\" viewBox=\"0 0 %d %d\" version=\"1.1\">",
            input.w, input.h, input.w, input.h);

        scope(exit) svgFile.writeln("</svg>");

        foreach (path; paths) {
            svgFile.writefln(
                "<polyline xmlns=\"http://www.w3.org/2000/svg\" points=\"%s\" style=\"fill:rgba(0, 0, 0, 0);stroke:rgba(0, 0, 0, 255);stroke-width:%d\"/>",
                path.map!(p => format("%f,%f", p.x, p.y)).join(" "), strokeWidth);
        }
    } catch (Exception e) {
        stderr.writefln("File write error: %s", e);
    }
}
