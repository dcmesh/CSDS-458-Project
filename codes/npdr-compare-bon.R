### Load packages

library(devtools)
install_github('insilico/privateEC')

library(privateEC)
library(broom)
library(tidyverse)
library(uniReg)

install_github('insilico/npdr') # npdr install
library(npdr)

rm(list = ls())
set.seed(1618)

cbbPalette <- c("#999999", "#E69F00", "#56B4E9", "#009E73", "#F0E442", 
                "#0072B2", "#D55E00", "#CC79A7", "#c5679b", "#be548f")


### Utility functions:
  
geneLowVarianceFilter <- function(dataMatrix, percentile=0.5) {
  variances <- apply(as.matrix(dataMatrix), 2, var)
  threshold <- quantile(variances, c(percentile))
  # remove variable columns with lowest percentile variance:
  mask <- apply(dataMatrix, 2, function(x) var(x) > threshold)
  fdata <- dataMatrix[, mask]
  # return the row mask and filtered data:
  list(mask=mask, fdata=fdata)
}

clean_df_results <- function(input_df, ana_name){
  input_df %>%
    data.frame() %>%
    rownames_to_column('att') %>%
    rename(!!sym(paste0('beta.', ana_name)) := beta,
           !!sym(paste0('pval.', ana_name)) := pval,
           !!sym(paste0('p.adj.', ana_name)) := p.adj)
}


### Load data:
  

load('data/0.8genes.filtered.corrected.Rdata') ### RNA-Seq data
dim(rnaSeq)  # 915 subjects x (15230 genes + 1 class)
mdd.pheno <- data.frame(class = phenos) %>% 
  rownames_to_column('ids')


### Assocation between MDD and sex:

pheno.sex <- covs.short %>% 
  select(sex) %>%
  rownames_to_column('ids') %>%
  merge(mdd.pheno, by = 'ids')
chisq.test(fam.data$affected, fam.data$sex)
# table(fam.data$affected, fam.data$sex)
table(pheno.sex$class, pheno.sex$sex)


### Filter RNA-Seq:

unfiltered.predictors.mat <- rnaSeq
# strict filter so it finishes in a couple minutes
# use .5 in real analysis, but it will take a while (a day?)
pct <- 0.95 # .5, 2957 genes 
filter <- geneLowVarianceFilter(unfiltered.predictors.mat, pct)
filtered.jerzy.df <- data.frame(filter$fdata) %>%
  rownames_to_column('ids') %>%
  merge(mdd.pheno, by = 'ids') %>%
  column_to_rownames('ids')
filtered.pred <- filtered.jerzy.df %>% select(-class)
dim(filtered.jerzy.df)


### Univariate analysis:


# Simple analysis with no sex adjustment:
# class.idx <- length(colnames(filtered.jerzy.df))
# colnames(filtered.jerzy.df)[class.idx]
rnaSeq_mdd <- rnaSeq %>%
  data.frame() %>%
  rownames_to_column('ids') %>%
  merge(mdd.pheno, by = 'ids') %>%
  column_to_rownames('ids')

gene_mdd <- univarRegress(
  outcome = 'class', 
  dataset = rnaSeq_mdd, 
  regression.type = 'glm') %>%
  clean_df_results('gene.mdd')

# After adjusting for sex:
gene_sex_mdd <- univarRegress(
  outcome = 'class', dataset = rnaSeq_mdd, 
  regression.type = 'glm', covars = pheno.sex$sex) %>%
  clean_df_results('gene.sex.mdd')

# Univariate with sex as outcome:
# check if the rows are the same order: 0 = good
sum(pheno.sex$ids != rownames(filtered.jerzy.df))

gene_sex <- univarRegress(
  outcome = pheno.sex$sex,
  dataset = filtered.pred,
  regression.type='glm') %>%
  clean_df_results('gene.sex')

# Summarize all univariate analyses:
uni_w_wo_sex <- data.frame(gene_mdd) %>%
  merge(gene_sex_mdd, by = 'att') %>%
  merge(gene_sex, by = 'att')



### Run NPDR, no covariate adjustment:

################################### 
start_time <- Sys.time()
npdr.mdd.rnaseq.results <- npdr('class', filtered.jerzy.df, regression.type='glm',
                                attr.diff.type='numeric-abs', nbd.method='multisurf', 
                                nbd.metric = 'manhattan', msurf.sd.frac=0.5,
                                padj.method='bonferroni')
end_time <- Sys.time()
end_time - start_time  # about 5 min for pct=.98, 306vars, 18min for pct=.9 and 1524 vars

npdr_mdd_nosex <- npdr.mdd.rnaseq.results %>%
  rename(beta.npdr.nosex = beta.Z.att,
         pval.npdr.nosex  = pval.att,
         p.adj.npdr.nosex = pval.adj)

### Run NPDR, adjusting for sex:

# sex-associated by npdr
start_time <- Sys.time()
npdr.mdd.sexassoc.results <- npdr('class', filtered.jerzy.df, 
                                  regression.type='glm', attr.diff.type='numeric-abs',
                                  nbd.method='multisurf', nbd.metric = 'manhattan',
                                  covars=pheno.sex$sex,  # works with sex.covar.mat as well
                                  covar.diff.type='match-mismatch', # for categorical covar like sex
                                  msurf.sd.frac=0.5, padj.method='bonferroni')
end_time <- Sys.time()
end_time - start_time  # about 5 min for pct=.98, 306vars

npdr_mdd_sex <- npdr.mdd.sexassoc.results %>%
  rename(beta.npdr.sex = beta.Z.att,
         pval.npdr.sex  = pval.att,
         p.adj.npdr.sex = pval.adj)

npdr_w_wo_sex <- data.frame(gene_sex) %>%
  merge(npdr_mdd_nosex, by = 'att') %>%
  merge(npdr_mdd_sex, by = 'att') %>%
  mutate(nlog10.nosex = -log10(p.adj.npdr.nosex)) %>%
  mutate(nlog10.sex = -log10(p.adj.npdr.sex)) %>%
  mutate(significant = as.factor((p.adj.npdr.nosex < 0.01) + (p.adj.npdr.sex < 0.01))) %>%
  mutate(sig.genes = ifelse((p.adj.npdr.nosex < 0.01) | p.adj.npdr.sex < 0.01, att, NA)) %>%
  mutate(nlog10.sex.genes = -log10(p.adj.gene.sex))

save(npdr_w_wo_sex, uni_w_wo_sex, file = paste0('results/', pct, '_jerzy_mdd_results.Rdata'))

set.seed(1618)
ranfor.fit <- randomForest::randomForest(as.factor(class) ~ ., data = filtered.jerzy.df, importance = T) 
rf.importance <- randomForest::importance(ranfor.fit)  # variable 3 best
rf_imp_sorted <- rf.importance %>%
  data.frame() %>%
  rownames_to_column('att') 

save(rf_imp_sorted, file = paste0('results/rf_', pct, '_jerzy_mdd_results.Rdata'))
