#include "coremark.h"

/* Function: iterate
        Run the benchmark for a specified number of iterations.

        Operation:
        For each type of benchmarked algorithm:
                a - Initialize the data block for the algorithm.
                b - Execute the algorithm N times.

        Returns:
        NULL.
*/


void *
iterate(void *pres)
{
    ee_u32        i;
    ee_u16        crc;
    core_results *res        = (core_results *)pres;
    ee_u32        iterations = res->iterations;
    res->crc                 = 0;
    res->crclist             = 0;
    res->crcmatrix           = 0;
    res->crcstate            = 0;

    for (i = 0; i < iterations; i++)
    {
        crc      = core_bench_list(res, 1);
        res->crc = crcu16(crc, res->crc);
        crc      = core_bench_list(res, -1);
        res->crc = crcu16(crc, res->crc);
        if (i == 0)
            res->crclist = res->crc;
    }
    return NULL;
}

