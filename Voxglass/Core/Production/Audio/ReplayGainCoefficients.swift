import Foundation

public enum ReplayGainCoefficients {
    public static let supportedRates: Set<Int> = [44100, 48000]

    static func yuleB(for sampleRate: Int) -> [Double]? {
        switch sampleRate {
        case 48000: return yule48kB
        case 44100: return yule441kB
        default: return nil
        }
    }

    static func yuleA(for sampleRate: Int) -> [Double]? {
        switch sampleRate {
        case 48000: return yule48kA
        case 44100: return yule441kA
        default: return nil
        }
    }

    static func butterworthB(for sampleRate: Int) -> [Double]? {
        switch sampleRate {
        case 48000: return butter48kB
        case 44100: return butter441kB
        default: return nil
        }
    }

    static func butterworthA(for sampleRate: Int) -> [Double]? {
        switch sampleRate {
        case 48000: return butter48kA
        case 44100: return butter441kA
        default: return nil
        }
    }

    private static let yule48kB: [Double] = [
        0.03857599435200, -0.02160367184185, -0.00123395316851, -0.00009291677959,
        -0.01655260341619,  0.02161526843274, -0.02074045215285,  0.00594298065125,
         0.00306428023191,  0.00012025322027,  0.00288463683916,
    ]

    private static let yule48kA: [Double] = [
        1.00000000000000, -3.84664617118067,  7.81501653005538, -11.34170355132042,
       13.05504219327545, -12.28759895145294,  9.48293806319790,  -5.87257861775999,
        2.75465861874613,  -0.86984376593551,  0.13919314567432,
    ]

    private static let butter48kB: [Double] = [
        0.98621192462708, -1.97242384925416, 0.98621192462708,
    ]

    private static let butter48kA: [Double] = [
        1.00000000000000, -1.97223372919527, 0.97261396931306,
    ]

    private static let yule441kB: [Double] = [
        0.05418656406430, -0.02911007808948, -0.00848709379851, -0.00851165645469,
        -0.00834990904936,  0.02245293253339, -0.02596338512915,  0.01624864962975,
        -0.00240879051584,  0.00674613682247, -0.00187763777362,
    ]

    private static let yule441kA: [Double] = [
        1.00000000000000, -3.47845948550071,  6.36317777566148, -8.54751527471874,
        9.47693607801280, -8.81498681370155,  6.85401540936998, -4.39470996079559,
        2.19611684890774, -0.75104302451432,  0.13149317958808,
    ]

    private static let butter441kB: [Double] = [
        0.98500175787242, -1.97000351574484, 0.98500175787242,
    ]

    private static let butter441kA: [Double] = [
        1.00000000000000, -1.96977855582618, 0.97022847566350,
    ]
}
