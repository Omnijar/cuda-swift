import XCTest
@testable import CUDARuntime
import NVRTC

class CUDARuntimeTests: XCTestCase {

    func testDevice() {
        let computability = CUDARuntime.Device.current!.computeCapability
        XCTAssertGreaterThanOrEqual(computability.major, 1)
        XCTAssertGreaterThanOrEqual(computability.minor, 0)
    }

    func testPointer() {
        measure {
            let localArray: ContiguousArray = [1, 2, 3, 4, 5, 6, 7, 8]
            let pointer = UnsafeMutableDevicePointer<Int>.allocate(capacity: 8)
            pointer.assign(fromHost: localArray)
            XCTAssertEqual(pointer.load(), 1)
            for i in localArray.indices {
                XCTAssertEqual(localArray[i], pointer[i])
            }
            /// Add one to each device element
            for i in localArray.indices {
                pointer[i] += 1
                XCTAssertEqual(localArray[i] + 1, pointer[i])
            }
            pointer.deallocate()
        }
    }

    func testArray() {
        let hostArray: [Int] = [1, 2, 3, 4, 5]
        /// Array literal initialization!
        let devArray: DeviceArray<Int> = [1, 2, 3, 4, 5]
        XCTAssertEqual(hostArray, Array(devArray))
        let hostArrayFromDev: [Int] = devArray.copyToHost()
        XCTAssertEqual(hostArray, hostArrayFromDev)

        /// Test copy-on-write
        var devArray2 = devArray
        var devArray3 = devArray
        let devArray4 = devArray3
        devArray2[0].value = 3
        XCTAssertNotEqual(Array(devArray), Array(devArray2))
        devArray2[0] = DeviceValue(1)
        XCTAssertEqual(Array(devArray), Array(devArray2))
        devArray3[0].value = 4
        var val3_0 = devArray3[0]
        var origVal3_0 = val3_0
        XCTAssertEqual(val3_0.value, 4)
        val3_0.value = 10
        XCTAssertEqual(val3_0.value, 10)
        XCTAssertEqual(origVal3_0.value, 4)
        var devArray5 = devArray
        let val5_0 = devArray5[0]
        devArray5[0].value = 100
        XCTAssertEqual(val5_0.value, 1)
        devArray5[0] = DeviceValue(100)
        XCTAssertEqual(val5_0.value, 1)
        XCTAssertEqual(devArray5[0].value, 100)
        XCTAssertNotEqual(Array(devArray2), Array(devArray3))
        XCTAssertEqual(devArray.copyToHost(), Array(devArray))
        XCTAssertEqual(devArray.copyToHost(), [1, 2, 3, 4, 5])
        XCTAssertEqual(devArray2.copyToHost(), [1, 2, 3, 4, 5])
        XCTAssertEqual(devArray3.copyToHost(), [4, 2, 3, 4, 5])
        XCTAssertEqual(devArray4.copyToHost(), [1, 2, 3, 4, 5])

        /// Array slices
        var devArray6 = devArray // 1...5
        let devArray6_13 = devArray6[1...3]
        XCTAssertEqual(devArray6_13.copyToHost(), [2, 3, 4])
        devArray6[1].value = 20
        XCTAssertEqual(devArray6_13.copyToHost(), [2, 3, 4])
        XCTAssertEqual(devArray6.copyToHost(), [1, 20, 3, 4, 5])

        /// Array value reference
        var V: DeviceArray<Float> = [1, 2, 3]
        let x = V[2]
        XCTAssertEqual(x.value, 3)
        V[2] = DeviceValue(0)
        XCTAssertEqual(x.value, 3)
        V[2].value = 100
        XCTAssertEqual(x.value, 3)

        /// Nested device array literal
        var VV: DeviceArray<DeviceArray<DeviceArray<Float>>> = [
            [[1, 0], [1, 2], [1, 3], [1, 4], [1, 5]],
            [[1, 2], [1, 2], [1, 3], [1, 4], [1, 5]],
        ]
        XCTAssertEqual(VV[0][1].copyToHost(), [1, 2])
        XCTAssertEqual(VV[1][4].copyToHost(), [1, 5])
        let row1: [[Float]] = VV[1].copyToHost()
        let row1ShouldBe: [[Float]] = [[1, 2], [1, 2], [1, 3], [1, 4], [1, 5]]
        XCTAssertTrue(row1.elementsEqual(row1ShouldBe, by: { (xx, yy) in
            xx.elementsEqual(yy)
        }))

        /// Nested array reference literal
        /// Currently mutation FAILS
        var VV1: DeviceArray<DeviceArray<Float>> = {
            let vv1_0: DeviceArray<Float> = [1, 2, 3]
            let vv1_1: DeviceArray<Float> = [4, 5, 6]
            return [ vv1_0, vv1_1 ]
        }()
        XCTAssertEqual(VV1[0].copyToHost(), [1, 2, 3])
        XCTAssertEqual(VV1[1].copyToHost(), [4, 5, 6])
        XCTAssertEqual(VV1[0][0].value, 1)
        XCTAssertEqual(VV1[0][1].value, 2)
        XCTAssertEqual(VV1[0][2].value, 3)
        XCTAssertEqual(VV1[1][0].value, 4)
        XCTAssertEqual(VV1[1][1].value, 5)
        XCTAssertEqual(VV1[1][2].value, 6)
    }

    func testValue() {
        var val = DeviceValue<Int>(1)
        XCTAssertEqual(val.value, 1)
        var val2 = val
        val2.value = 10
        XCTAssertEqual(val.value, 1)
        XCTAssertEqual(val2.value, 10)

        /// Test memory mutation
        val.withUnsafeMutableDevicePointer { ptr in
            ptr.assign(100)
        }
        XCTAssertEqual(val.value, 100)
        XCTAssertNotEqual(val2.value, val.value)

        /// Test CoW memory mutation
        var val3 = val
        val3.withUnsafeMutableDevicePointer { ptr in
            ptr.assign(1000)
        }
        XCTAssertEqual(val3.value, 1000)
        XCTAssertNotEqual(val3.value, val.value)
    }
    
    func testModuleMult() throws {
        let source: String =
            "extern \"C\" __global__ void mult(float a, float *x, size_t n) {"
          + "    size_t i = blockIdx.x * blockDim.x + threadIdx.x;"
          + "    if (i < n) x[i] = a * x[i];"
          + "}";
        let ptx = try Compiler.compile(
            Program(source: source),
            options: [
                .computeCapability(Device.current!.computeCapability),
                .cpp11,
                .lineInfo,
                .contractIntoFMAD(true),
            ]
        )
        let module = try Module(ptx: ptx)
        let mult = module.function(named: "mult")!
        var x = DeviceArray<Float>(fromHost: Array(sequence(first: 0.0, next: {$0+1}).prefix(256)))
        let y = x /// To test copy-on-write
        
        var args = ArgumentList()
        args.append(Float(5.0))
        args.append(&x)
        args.append(Int32(256))

        let stream = CUDARuntime.Stream()
        stream.addCallback { stream, error in
            debugPrint("Callback called!")
            XCTAssertNil(error)
            XCTAssertNotNil(stream)
        }

        try mult<<<(8, 32, 0, stream)>>>(args)

        XCTAssertNotEqual(x.copyToHost(), y.copyToHost())
        XCTAssertEqual(x.copyToHost(), [0.0, 5.0, 10.0, 15.0, 20.0, 25.0, 30.0, 35.0, 40.0, 45.0, 50.0, 55.0, 60.0, 65.0, 70.0, 75.0, 80.0, 85.0, 90.0, 95.0, 100.0, 105.0, 110.0, 115.0, 120.0, 125.0, 130.0, 135.0, 140.0, 145.0, 150.0, 155.0, 160.0, 165.0, 170.0, 175.0, 180.0, 185.0, 190.0, 195.0, 200.0, 205.0, 210.0, 215.0, 220.0, 225.0, 230.0, 235.0, 240.0, 245.0, 250.0, 255.0, 260.0, 265.0, 270.0, 275.0, 280.0, 285.0, 290.0, 295.0, 300.0, 305.0, 310.0, 315.0, 320.0, 325.0, 330.0, 335.0, 340.0, 345.0, 350.0, 355.0, 360.0, 365.0, 370.0, 375.0, 380.0, 385.0, 390.0, 395.0, 400.0, 405.0, 410.0, 415.0, 420.0, 425.0, 430.0, 435.0, 440.0, 445.0, 450.0, 455.0, 460.0, 465.0, 470.0, 475.0, 480.0, 485.0, 490.0, 495.0, 500.0, 505.0, 510.0, 515.0, 520.0, 525.0, 530.0, 535.0, 540.0, 545.0, 550.0, 555.0, 560.0, 565.0, 570.0, 575.0, 580.0, 585.0, 590.0, 595.0, 600.0, 605.0, 610.0, 615.0, 620.0, 625.0, 630.0, 635.0, 640.0, 645.0, 650.0, 655.0, 660.0, 665.0, 670.0, 675.0, 680.0, 685.0, 690.0, 695.0, 700.0, 705.0, 710.0, 715.0, 720.0, 725.0, 730.0, 735.0, 740.0, 745.0, 750.0, 755.0, 760.0, 765.0, 770.0, 775.0, 780.0, 785.0, 790.0, 795.0, 800.0, 805.0, 810.0, 815.0, 820.0, 825.0, 830.0, 835.0, 840.0, 845.0, 850.0, 855.0, 860.0, 865.0, 870.0, 875.0, 880.0, 885.0, 890.0, 895.0, 900.0, 905.0, 910.0, 915.0, 920.0, 925.0, 930.0, 935.0, 940.0, 945.0, 950.0, 955.0, 960.0, 965.0, 970.0, 975.0, 980.0, 985.0, 990.0, 995.0, 1000.0, 1005.0, 1010.0, 1015.0, 1020.0, 1025.0, 1030.0, 1035.0, 1040.0, 1045.0, 1050.0, 1055.0, 1060.0, 1065.0, 1070.0, 1075.0, 1080.0, 1085.0, 1090.0, 1095.0, 1100.0, 1105.0, 1110.0, 1115.0, 1120.0, 1125.0, 1130.0, 1135.0, 1140.0, 1145.0, 1150.0, 1155.0, 1160.0, 1165.0, 1170.0, 1175.0, 1180.0, 1185.0, 1190.0, 1195.0, 1200.0, 1205.0, 1210.0, 1215.0, 1220.0, 1225.0, 1230.0, 1235.0, 1240.0, 1245.0, 1250.0, 1255.0, 1260.0, 1265.0, 1270.0, 1275.0])
    }

    func testModuleSaxpy() {
        do {
            let source =
                "extern \"C\" __global__ void saxpy(float a, float *x, float *y, float *out, size_t n) {"
              + "    size_t tid = blockIdx.x * blockDim.x + threadIdx.x;"
              + "    if (tid < n) out[tid] = a * x[tid] + y[tid];"
              + "}"

            let ptx = try Compiler.compile(source, options: [
                .computeCapability(Device.current!.computeCapability),
                .contractIntoFMAD(false),
                .useFastMath
            ])
            let module = try Module(ptx: ptx)
            let saxpy = module.function(named: "saxpy")!
            
            /// Arguments
            var x = DeviceArray<Float>(fromHost: Array(sequence(first: 0, next: {$0+1}).prefix(512)))
            var y = DeviceArray<Float>(fromHost: Array(sequence(first: 512, next: {$0-1}).prefix(512)))
            var out = DeviceArray<Float>(capacity: 512)
            var args = ArgumentList()
            args.append(Float(5.1))
            args.append(&x)
            args.append(&y)
            args.append(&out)
            args.append(Int32(512))
            
            try saxpy<<<(32, 128)>>>(args)
            XCTAssertEqual(out.copyToHost(), [512.0, 516.099976, 520.200012, 524.299988, 528.400024, 532.5, 536.599976, 540.700012, 544.799988, 548.900024, 553.0, 557.099976, 561.200012, 565.299988, 569.400024, 573.5, 577.599976, 581.700012, 585.799988, 589.900024, 594.0, 598.099976, 602.200012, 606.299988, 610.400024, 614.5, 618.599976, 622.700012, 626.799988, 630.900024, 635.0, 639.099976, 643.200012, 647.299988, 651.400024, 655.5, 659.599976, 663.700012, 667.799988, 671.900024, 676.0, 680.099976, 684.200012, 688.299988, 692.400024, 696.5, 700.599976, 704.700012, 708.799988, 712.900024, 717.0, 721.099976, 725.199951, 729.299988, 733.400024, 737.5, 741.599976, 745.699951, 749.799988, 753.900024, 758.0, 762.099976, 766.199951, 770.299988, 774.400024, 778.5, 782.599976, 786.699951, 790.799988, 794.900024, 799.0, 803.099976, 807.199951, 811.299988, 815.400024, 819.5, 823.599976, 827.699951, 831.799988, 835.900024, 840.0, 844.099976, 848.199951, 852.299988, 856.400024, 860.5, 864.599976, 868.699951, 872.799988, 876.900024, 881.0, 885.099976, 889.199951, 893.299988, 897.400024, 901.5, 905.599976, 909.699951, 913.799988, 917.900024, 922.0, 926.099976, 930.200012, 934.299988, 938.399963, 942.5, 946.599976, 950.700012, 954.799988, 958.899963, 963.0, 967.099976, 971.200012, 975.299988, 979.399963, 983.5, 987.599976, 991.700012, 995.799988, 999.899963, 1004.0, 1008.09998, 1012.20001, 1016.29999, 1020.39996, 1024.5, 1028.59998, 1032.69995, 1036.80005, 1040.8999, 1045.0, 1049.09998, 1053.19995, 1057.30005, 1061.3999, 1065.5, 1069.59998, 1073.69995, 1077.80005, 1081.8999, 1086.0, 1090.09998, 1094.19995, 1098.30005, 1102.3999, 1106.5, 1110.59998, 1114.69995, 1118.80005, 1122.8999, 1127.0, 1131.09998, 1135.19995, 1139.30005, 1143.3999, 1147.5, 1151.59998, 1155.69995, 1159.80005, 1163.8999, 1168.0, 1172.09998, 1176.19995, 1180.30005, 1184.3999, 1188.5, 1192.59998, 1196.69995, 1200.80005, 1204.8999, 1209.0, 1213.09998, 1217.19995, 1221.30005, 1225.3999, 1229.5, 1233.59998, 1237.69995, 1241.80005, 1245.8999, 1250.0, 1254.09998, 1258.19995, 1262.30005, 1266.3999, 1270.5, 1274.59998, 1278.69995, 1282.80005, 1286.8999, 1291.0, 1295.09998, 1299.19995, 1303.30005, 1307.3999, 1311.5, 1315.59998, 1319.69995, 1323.80005, 1327.8999, 1332.0, 1336.09998, 1340.19995, 1344.29993, 1348.40002, 1352.5, 1356.59998, 1360.69995, 1364.79993, 1368.90002, 1373.0, 1377.09998, 1381.19995, 1385.29993, 1389.40002, 1393.5, 1397.59998, 1401.69995, 1405.79993, 1409.90002, 1414.0, 1418.09998, 1422.19995, 1426.29993, 1430.40002, 1434.5, 1438.59998, 1442.69995, 1446.79993, 1450.90002, 1455.0, 1459.09998, 1463.19995, 1467.29993, 1471.40002, 1475.5, 1479.59998, 1483.69995, 1487.79993, 1491.90002, 1496.0, 1500.09998, 1504.19995, 1508.29993, 1512.40002, 1516.5, 1520.59998, 1524.69995, 1528.79993, 1532.90002, 1537.0, 1541.09998, 1545.19995, 1549.29993, 1553.40002, 1557.5, 1561.59998, 1565.69995, 1569.79993, 1573.90002, 1578.0, 1582.09998, 1586.19995, 1590.29993, 1594.40002, 1598.5, 1602.59998, 1606.69995, 1610.79993, 1614.90002, 1619.0, 1623.09998, 1627.19995, 1631.29993, 1635.40002, 1639.5, 1643.59998, 1647.69995, 1651.79993, 1655.90002, 1660.0, 1664.09998, 1668.19995, 1672.29993, 1676.40002, 1680.5, 1684.59998, 1688.69995, 1692.79993, 1696.90002, 1701.0, 1705.09998, 1709.19995, 1713.29993, 1717.40002, 1721.5, 1725.59998, 1729.69995, 1733.79993, 1737.90002, 1742.0, 1746.09998, 1750.19995, 1754.29993, 1758.40002, 1762.5, 1766.59998, 1770.69995, 1774.79993, 1778.90002, 1783.0, 1787.09998, 1791.19995, 1795.29993, 1799.40002, 1803.5, 1807.59998, 1811.69995, 1815.79993, 1819.90002, 1824.0, 1828.09998, 1832.19995, 1836.29993, 1840.40002, 1844.5, 1848.59998, 1852.69995, 1856.79993, 1860.90002, 1865.0, 1869.09998, 1873.19995, 1877.29993, 1881.40002, 1885.5, 1889.59998, 1893.69995, 1897.79993, 1901.90002, 1906.0, 1910.09998, 1914.19995, 1918.29993, 1922.40002, 1926.5, 1930.59998, 1934.69995, 1938.79993, 1942.90002, 1947.0, 1951.09998, 1955.19995, 1959.29993, 1963.40002, 1967.5, 1971.59998, 1975.69995, 1979.79993, 1983.90002, 1988.0, 1992.09998, 1996.19995, 2000.29993, 2004.40002, 2008.5, 2012.59998, 2016.69995, 2020.79993, 2024.90002, 2029.0, 2033.09998, 2037.19995, 2041.29993, 2045.40002, 2049.5, 2053.6001, 2057.69995, 2061.7998, 2065.8999, 2070.0, 2074.1001, 2078.19995, 2082.2998, 2086.3999, 2090.5, 2094.6001, 2098.69995, 2102.7998, 2106.8999, 2111.0, 2115.1001, 2119.19995, 2123.2998, 2127.3999, 2131.5, 2135.6001, 2139.69995, 2143.7998, 2147.8999, 2152.0, 2156.1001, 2160.19995, 2164.30005, 2168.3999, 2172.5, 2176.59985, 2180.69995, 2184.80005, 2188.8999, 2193.0, 2197.09985, 2201.19995, 2205.30005, 2209.3999, 2213.5, 2217.59985, 2221.69995, 2225.80005, 2229.8999, 2234.0, 2238.09985, 2242.19995, 2246.30005, 2250.3999, 2254.5, 2258.59985, 2262.69995, 2266.80005, 2270.8999, 2275.0, 2279.09985, 2283.19995, 2287.30005, 2291.3999, 2295.5, 2299.59985, 2303.69995, 2307.80005, 2311.8999, 2316.0, 2320.09985, 2324.19995, 2328.30005, 2332.3999, 2336.5, 2340.59985, 2344.69995, 2348.80005, 2352.8999, 2357.0, 2361.09985, 2365.19995, 2369.30005, 2373.3999, 2377.5, 2381.59985, 2385.69995, 2389.80005, 2393.8999, 2398.0, 2402.09985, 2406.19995, 2410.30005, 2414.3999, 2418.5, 2422.59985, 2426.69995, 2430.80005, 2434.8999, 2439.0, 2443.09985, 2447.19995, 2451.30005, 2455.3999, 2459.5, 2463.59985, 2467.69995, 2471.80005, 2475.8999, 2480.0, 2484.09985, 2488.19995, 2492.30005, 2496.3999, 2500.5, 2504.59985, 2508.69995, 2512.80005, 2516.8999, 2521.0, 2525.09985, 2529.19995, 2533.30005, 2537.3999, 2541.5, 2545.59985, 2549.69995, 2553.80005, 2557.8999, 2562.0, 2566.09985, 2570.19995, 2574.30005, 2578.3999, 2582.5, 2586.59985, 2590.69995, 2594.80005, 2598.8999, 2603.0, 2607.09985])
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    static var allTests : [(String, (CUDARuntimeTests) -> () throws -> Void)] {
        return [
            ("testDevice", testDevice),
            ("testPointer", testPointer),
            ("testArray", testArray),
            ("testValue", testValue),
            ("testModuleMult", testModuleMult),
            ("testModuleSaxpy", testModuleSaxpy)
        ]
    }
}
