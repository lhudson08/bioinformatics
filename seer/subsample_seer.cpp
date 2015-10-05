// Calculates power of seer
// Assumes ~50% of samples have phenotype

// C/C++/C++11 headers
#include <iostream>
#include <fstream>
#include <cmath>
#include <cstdlib>
#include <string>
#include <algorithm>
#include <iterator>
#include <vector>
#include <unordered_map>
#include <regex>
#include <stdlib.h>
#include <stdio.h>

// Armadillo/dlib headers
#include <armadillo>

// Test size and range set here
const double start_OR = 0.5;
const double OR_step = 1;
const double end_OR = 5.5;

const int start_samples = 50;
const int samples_step = 50;
const int end_samples = 3000;

const double repeats = 100;

const double element_MAF = 0.25; // Number of samples gene/SNP is in
const double target_Sr = 1; // Ratio of cases to controls

const std::string kmer_input = "gene_kmers.txt.gz";

struct Sample
{
   std::string sample_name;
   int element_present;
};

// Functions
std::vector<int> reservoir_sample(const size_t size, const size_t max_size); // Indices of samples subsampled
std::string cut_struct_mat(const arma::mat& struct_mat, const std::vector<int>& rows); // Extracts only the used rows of the pop_struct matrix
double p_case_ne(const double OR, const double MAF, const double Sr);
double p_case_e(const double OR, const double MAF, const double Sr);
std::string generate_pheno(const std::vector<Sample>& sample_names, const std::vector<int>& kept_indices, const double p_ne);
std::string exec(const char* cmd);

// Functors
struct seer_hits
{
   seer_hits(const std::vector<Sample> _sample_names, const arma::mat _dsm_mat, const double _MAF, const double _Sr) : sample_names(_sample_names), dsm_mat(_dsm_mat), MAF(_MAF), Sr(_Sr)
   {
   }

   int operator()(const size_t num_samples, const double OR) const
   {
      std::vector<int> samples_kept = reservoir_sample(num_samples, sample_names.size());
      std::string pheno_file = generate_pheno(sample_names, samples_kept, p_case_ne(OR, MAF, Sr));
      std::string struct_mat = cut_struct_mat(dsm_mat, samples_kept);

      std::string seer_cmd = "./seer -k " + kmer_input + " -p " + pheno_file + " --struct " + struct_mat;
      std::string seer_return = exec(seer_cmd.c_str());

      // Delete tmp files
      std::remove(pheno_file.c_str());
      std::remove(struct_mat.c_str());

      return stoi(seer_return);
   }

   private:
      std::vector<Sample> sample_names;
      arma::mat dsm_mat;
      const double MAF;
      const double Sr;
};

std::vector<int> reservoir_sample(const size_t size, const size_t max_size)
{
   std::vector<int> sample_indices;

   for (int i = 1; i <= size; ++i)
   {
      sample_indices.push_back(i);
   }

   for (int i = size + 1; i<= max_size; ++i)
   {
      int j = rand() % i + 1;
      if (j <= size)
      {
         sample_indices[j] = i;
      }
   }

   return sample_indices;
}

std::string generate_pheno(const std::vector<Sample>& sample_names, const std::vector<int>& kept_indices, const double p_ne)
{
   char * tmp_name_ptr;
   tmp_name_ptr = std::tmpnam(NULL);

   std::ofstream pheno_file(tmp_name_ptr);
   if (!pheno_file)
   {
      throw std::runtime_error("Could not write to tmp pheno file");
   }

   double p_e = 1 - p_ne;
   for (auto keep_it = kept_indices.begin(); keep_it != kept_indices.end(); ++keep_it)
   {
      // Generate pheno based on OR here
      int pheno = 0;
      double rand_nr = rand();
      if ((sample_names[*keep_it].element_present && rand_nr < p_e) ||
            (!sample_names[*keep_it].element_present && rand_nr < p_ne))
      {
         pheno = 1;
      }

      pheno_file << sample_names[*keep_it].sample_name << "\t" << pheno << "\n";
   }

   std::string file_name(tmp_name_ptr);
   return file_name;
}

// Given a sample doesn't have the kmer, return the probability of having case
// phenotype
// Sr is the sample ratio
double p_case_ne(const double OR, const double MAF, const double Sr)
{
   return(pow((1+pow(Sr, -1))*(MAF*(OR - 1) + 1), -1));
}

double p_case_e(const double OR, const double MAF, const double Sr)
{
   return(1 - p_case_ne(OR, MAF, Sr));
}

std::string cut_struct_mat(const arma::mat& struct_mat, const std::vector<int>& rows)
{
   arma::uvec keep_rows(rows.size());
   int i = 0;
   for (auto it = rows.begin(); it != rows.end(); ++it)
   {
      keep_rows[i] = *it;
      ++i;
   }

   arma::mat tmp_struct = struct_mat.rows(keep_rows);

   char * tmp_name_ptr;
   tmp_name_ptr = std::tmpnam(NULL);
   tmp_struct.save(tmp_name_ptr);

   std::string file_name(tmp_name_ptr);
   return file_name;
}

// From http://stackoverflow.com/questions/478898/how-to-execute-a-command-and-get-output-of-command-within-c
// Captures command output
std::string exec(const char* cmd)
{
    FILE* pipe = popen(cmd, "r");
    if (!pipe) return "ERROR";
    char buffer[128];
    std::string result = "";
    while (!feof(pipe)) {
        if (fgets(buffer, 128, pipe) != NULL)
            result += buffer;
    }
    pclose(pipe);
    return result;
}

int main (int argc, char *argv[])
{
   if (argc != 3)
   {
      throw std::runtime_error("Usage is: ./subsample_seer sample_names.txt dsm_matrix");
   }

   std::vector<Sample> all_samples;
   std::ifstream sample_file(argv[1]);
   if (!sample_file)
   {
      throw std::runtime_error("Could not open sample file");
   }

   while (sample_file)
   {
      Sample sample_read;
      std::string name_buf, present_buf;
      sample_file >> name_buf >> present_buf;

      sample_read.sample_name = name_buf;
      sample_read.element_present = stoi(present_buf);

      all_samples.push_back(sample_read);
   }

   arma::mat struct_mat;
   std::string dsm_file_name(argv[2]);
   bool mds_loaded = struct_mat.load(dsm_file_name);
   if (!mds_loaded)
   {
      throw std::runtime_error("Could not load mds matrix " + dsm_file_name);
   }

   // Loop over odds ratios, then sample number
   // (const std::vector<std::string> _sample_names, const arma::mat _dsm_mat, const double _OR, const double _MAF, const double _Sr, const size_t _max_samples
   seer_hits run_seer(all_samples, struct_mat, element_MAF, target_Sr);
   for (int OR = start_OR; OR <= end_OR; OR += OR_step)
   {
      for (int num_samples = start_samples; num_samples <= end_samples; num_samples += samples_step)
      {
         for (int repeat = 1; repeat <= repeats; ++repeat)
         {
            std::cout << OR << "\t" << num_samples << "\t" << repeat << "\t" << run_seer(OR, num_samples) << "\n";
         }
      }
   }

   return 0;
}

