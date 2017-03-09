module run_analysis;

/*
This module contains the main routines for analysing the data, it is called once for each phenotype:

1. For each phenotype we first extract all the genotypes from the cis window, then looping over all SNPs:

    2a. A general eQTL effect of the SNP is regressed from the phenotype.
    2b. A spearman correlation test is performed between the square of these residuals and the genotype dosage.
    2c. The correlation and P value is stored for each SNP.
    2d. A number of permutation tests are performed, testing genotype dosage against a permutation of the
        squared residuals. This is used to calculate a permutation P value for that SNP and if the perm P
        value is smaller than the minimum P value seen for that permutation for previous SNPs, this new
        value is stored.

3. Once each SNP has been analysed we have a collection of permutation P values generated under the null
hypothesis of no assocation. The parameters of the beta distribution best fitting this collection is estimated.

4. We loop over all SNPs again, calculating P values adjusted for multiple testing both by comparing against the
collection of minimum P values and against the beta distribution, writing out results.
 */

import calculation : betaParameters, corPvalue, correlation, Opts, rank,
  rank_discrete, transform, VarianceException;
import read_data : Genotype, Phenotype, readGenotype;
import std.algorithm : count, map, max, sort;
import std.array : array;
import std.conv : to;
import std.format : format;
import std.math : fabs, pow;
import std.numeric : dotProduct;
import std.range : chunks, indexed, iota, SearchPolicy, zip;
import std.stdio : File, stderr, writeln;

enum double EPSILON = 0.00000001; //comparison for X>=Y is done X > Y - epsilon

pure nothrow extern (C)
{
  //call GSL to calculate P values from T statistics
  double gsl_cdf_beta_P(double x, double alpha, double beta);

  struct gsl_block_struct
  {
    size_t size;
    double* data;
  }

  alias gsl_block = gsl_block_struct;

  struct gsl_matrix
  {
    size_t size1;
    size_t size2;
    size_t tda;
    double* data;
    gsl_block* block;
    int owner;
  }

  struct gsl_vector
  {
    size_t size;
    size_t stride;
    double* data;
    gsl_block* block;
    int owner;
  }

  struct gsl_multifit_linear_workspace
  {
    size_t n; /* number of observations */
    size_t p; /* number of parameters */
    gsl_matrix* A;
    gsl_matrix* Q;
    gsl_matrix* QSI;
    gsl_vector* S;
    gsl_vector* t;
    gsl_vector* xt;
    gsl_vector* D;
  }

  gsl_vector* gsl_vector_alloc(size_t n);
  void gsl_vector_free(gsl_vector* v);

  double gsl_vector_get(const gsl_vector* v, const size_t i);
  void gsl_vector_set(gsl_vector* v, const size_t i, double x);

  gsl_matrix* gsl_matrix_alloc(size_t n1, size_t n2);
  void gsl_matrix_free(gsl_matrix* m);

  void gsl_matrix_set_all(gsl_matrix* m, double x);

  double gsl_matrix_get(const gsl_matrix* m, const size_t i, const size_t j);
  void gsl_matrix_set(gsl_matrix* m, const size_t i, const size_t j, double x);

  gsl_multifit_linear_workspace* gsl_multifit_linear_alloc(const size_t n, const size_t p);
  void gsl_multifit_linear_free(gsl_multifit_linear_workspace* work);

  int gsl_multifit_linear(const gsl_matrix* X, const gsl_vector* y, gsl_vector* c,
      gsl_matrix* cov, double* chisq, gsl_multifit_linear_workspace* work);

  int gsl_multifit_linear_residuals(const gsl_matrix* X, const gsl_vector* y,
      const gsl_vector* c, gsl_vector* r);

}
void analyseData(ref Phenotype phenotype, ref size_t[] perms, ref File outFile,
    const ref Opts opts, ref size_t[] orderBuffer)
{
  auto genotype = readGenotype(opts, phenotype.chromosome, phenotype.location, phenotype.geneName);

  if (opts.verbose)
  {
    stderr.writeln("Extracted ", genotype.length, " usable genotypes.");
  }

  mapVeQTL(opts, perms, phenotype, genotype, outFile, orderBuffer);
}

void mapVeQTL(ref const Opts opts, ref size_t[] perms, ref Phenotype phenotype,
    ref Genotype[] genotypes, ref File outFile, ref size_t[] orderBuffer)
{
  immutable size_t nInd = phenotype.values.length;
  immutable nPerm = opts.perms[0];

  auto distance = new double[](nInd);

  auto covariates = gsl_matrix_alloc(nInd, 3);
  gsl_matrix_set_all(covariates, 1.0);

  auto outcome = gsl_vector_alloc(nInd);
  foreach (i; 0 .. nInd)
    gsl_vector_set(outcome, i, phenotype.values[i]);

  auto workSpace = gsl_multifit_linear_alloc(nInd, 3);
  auto corrMat = gsl_matrix_alloc(3, 3);
  auto coefficients = gsl_vector_alloc(3);
  double chisq;
  auto residuals = gsl_vector_alloc(nInd);

  double[] maxCor = new double[](nPerm);
  //we need to store greatest statistic across all SNPs in maxCor
  maxCor[] = 0.0;
  foreach (ref genotype; genotypes)
  {
    try
    {

      foreach (i; 0 .. nInd)
      {
        gsl_matrix_set(covariates, i, 1, genotype.values[i] > 2.0 / 3
            && genotype.values[i] < 4.0 / 3 ? 1 : 0);
        gsl_matrix_set(covariates, i, 2, genotype.values[i] > 4.0 / 3 ? 1 : 0);
      }

      gsl_multifit_linear(covariates, outcome, coefficients, corrMat, &chisq, workSpace);
      gsl_multifit_linear_residuals(covariates, outcome, coefficients, residuals);

      foreach (i; 0 .. nInd)
        distance[i] = pow(gsl_vector_get(residuals, i), 2);

      transform(rank(distance, orderBuffer));

      if (opts.het)
      {
        foreach (i; 0 .. genotype.values.length)
        {
          genotype.values[i] = genotype.values[i] > 2.0 / 3 && genotype.values[i] < 4.0 / 3 ? 1.0
            : 0.0;
        }
        transform(rank_discrete(genotype.values));
      }
      else
      {
        transform(rank(genotype.values, orderBuffer));
      }

      auto simplePerm = map!(a => fabs(dotProduct(genotype.values, distance.indexed(a))))(chunks(perms,
          nInd)).array;

      foreach (e; zip(iota(nPerm), simplePerm))
      {
        maxCor[e[0]] = max(maxCor[e[0]], e[1]);
      }

      auto corr = correlation(distance, genotype.values);

      genotype.cor = fabs(corr[0]);

      genotype.snpId ~= format("%s\t%s\t%s", corr[0], corr[1],
          (1.0 + simplePerm.count!(a => a > genotype.cor - EPSILON)) / (nPerm + 1));
    }
    catch (VarianceException e)
    {
      genotype.cor = 2;
    }
  }

  //sort stored maximum statistics
  auto sortMax = maxCor.sort();
  immutable double len = sortMax.length + 1.0;
  auto minPvalues = sortMax.map!(a => corPvalue(a, nInd)).array;
  auto betaParam = betaParameters(minPvalues);

  //read through old file and compare correlations to sortMax to calculate FWER
  foreach (genotype; genotypes)
  {
    if (genotype.cor != 2)
    {
      auto adjusted = (sortMax.upperBound!(SearchPolicy.gallop)(genotype.cor - EPSILON).length + 1) / len;
      auto betaP = gsl_cdf_beta_P(corPvalue(genotype.cor, nInd), betaParam[0], betaParam[1])
        .to!string;

      outFile.writeln(phenotype.geneName, genotype.snpId, "\t", adjusted.to!string, "\t", betaP);
    }
    else
    {
      outFile.writeln(phenotype.geneName, genotype.snpId, "\tNA\tNA\tNA\tNA");
    }
  }

  gsl_matrix_free(covariates);
  gsl_vector_free(outcome);
  gsl_multifit_linear_free(workSpace);
  gsl_matrix_free(corrMat);
  gsl_vector_free(coefficients);
  gsl_vector_free(residuals);

}
