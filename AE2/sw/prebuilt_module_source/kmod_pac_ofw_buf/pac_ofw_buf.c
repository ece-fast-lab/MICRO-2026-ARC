#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/module.h>
#include <linux/printk.h>
#include <linux/proc_fs.h>
#include <linux/uaccess.h>
#include <linux/mm.h>  // page_to_pfn
#include <linux/gfp.h> // alloc_contig_pages
#include <linux/io.h>

MODULE_DESCRIPTION("PAC_OFW_BUF");

MODULE_AUTHOR("");
MODULE_LICENSE("GPL");

#define BITS_PER_BYTE     8

#define CXL_NODE 1
#define MEMORY_ALLOC_NODE 0

#define MIG_GRP_SIZE 1
#define TRACER_REGION_SIZE  (4096 * 4096) // MIG_GRP_SIZE // 4 kB (1024 page) * MIG_GRP_SIZE
#define DMA32_MAX_ADDR   0xFFFFFFFFULL

/** Function Headers */
static ssize_t procfile_read(struct file *file, char __user *buffer, size_t buf_size, loff_t *offset);
static ssize_t procfile_write(struct file *file, const char __user *buffer, size_t buf_size, loff_t *offset);
static int procfile_mmap(struct file *file, struct vm_area_struct *vma);
static unsigned long allocate_tracer_region(int nid);
static void free_tracer_region(unsigned long pa);

/** File Scope Variables */
static struct proc_dir_entry *my_proc_file;
static const struct proc_ops proc_file_fops = {
    .proc_read = procfile_read,
    .proc_write = procfile_write,
    .proc_mmap = procfile_mmap
};
static unsigned long buf_pa = 0;
static unsigned long buf_pfn = 0;


/**
 * *************************
 * Init and Exit functions
 * *************************
*/
static int __init pac_ofw_buf_init(void) {

    pr_info("[INFO] Hello world! Initializing pac_ofw_buf module...\n");

    /* Create the process file for communication */
    my_proc_file = proc_create("pac_ofw_buf", 0644, NULL, &proc_file_fops);
    if (my_proc_file == NULL) {
        proc_remove(my_proc_file);
        pr_alert("[ERROR] Cannot initialize /proc/pac_ofw_buf \n");
        return -ENOMEM;
    }
    pr_info("[INFO] /proc/pac_ofw_buf created.\n");

    /* Create the 64kB buffer */
    buf_pa = allocate_tracer_region(MEMORY_ALLOC_NODE); // argument is the numa node id
    if (buf_pa == 0) {
        pr_alert("[ERROR] Buffer region creation on NODE%d failed.\n", MEMORY_ALLOC_NODE);
        return -ENOMEM;
    }
    pr_info("[INFO] Buffer region created on NODE %d. Paddr=0x%lx\n", MEMORY_ALLOC_NODE, buf_pa);

    /* Safety: refuse >4GB buffer to avoid 32-bit DMA truncation */
    if (buf_pa > DMA32_MAX_ADDR) {
        pr_err("[FATAL] pac_ofw_buf PA is above 4GB: 0x%lx (trunc->0x%08x). Fix allocation (DMA32) or FPGA (64-bit addr).\n",
               buf_pa, (u32)buf_pa);
        free_tracer_region(buf_pa);
        proc_remove(my_proc_file);
        return -ENOMEM;
    }

    /* Get the PFN of the buffer */
    buf_pfn = PHYS_PFN(buf_pa);

    return 0;
}



static void __exit pac_ofw_buf_exit(void) {

    pr_info("[INFO] Goodbye world. Cleaning up pac_ofw_buf module...\n"); 

    proc_remove(my_proc_file);
    pr_info("[INFO] /proc/pac_ofw_buf removed.\n");

    free_tracer_region(buf_pa);
    pr_info("[INFO] Buffer region freed.\n");

}

module_init(pac_ofw_buf_init);
module_exit(pac_ofw_buf_exit);



/**
 * ****************
 * File Operations
 * ****************
*/
static ssize_t procfile_read(struct file *file, char __user *buffer, size_t buf_size, loff_t *offset) {

    int len = sizeof(buf_pa);
    ssize_t ret = len;

    pr_info("[DEBUG] Trying to read from offset %lld.\n", *offset);
    
    /* Send physical address to user */
    if (*offset >= len || copy_to_user(buffer, &buf_pa, len)) {
        pr_info("[ERROR] Copy to user failed.\n");
        ret = 0;
    } else {
        pr_info("[INFO] Copy to user succeeded.\n");
        *offset += len;
    }

    return ret; 
}

static ssize_t procfile_write(struct file *file, const char __user *buffer, size_t buf_size, loff_t *offset) {

    char s[64];
    unsigned long len = sizeof(s);
    unsigned long copy_len = min(len, buf_size);

    
    if (copy_from_user(s, buffer, copy_len)) {
        pr_info("[ERROR] Copy from user failed.\n");
        return -EFAULT;
    }
    *offset += copy_len;

    pr_info("[DEBUG] Recieved %lu bytes from user.\n", copy_len);

    return copy_len;
}


// static int procfile_mmap(struct file *file, struct vm_area_struct *vma) {

//     int i = 0;
//     int ret;
// 	unsigned long pfn;
// 	// char *mem = (char *) buf_pa;
//     unsigned long size = vma->vm_end - vma->vm_start;

//     /* Sanity check */
//     if (size < TRACER_REGION_SIZE) {
//         pr_info("[ERROR] mmap virtual address range (0x%lx) is too small! Expect greater than: (0x%lx)\n", size, TRACER_REGION_SIZE);
//         return -ENOMEM;
//     }

//     pr_info("[DEBUG] mmap called. Page protection flag from vma struct is 0x%x\n", (uint32_t) vma->vm_page_prot.pgprot);

//     /* Map each page of the buffer to the given va range */
// 	for (i = 0; i < TRACER_REGION_SIZE / PAGE_SIZE; i++) {
//         pfn = buf_pfn + i;
// 		ret = remap_pfn_range(vma, vma->vm_start + i * PAGE_SIZE, pfn, PAGE_SIZE,  vma->vm_page_prot);
// 		if (ret) {
// 			pr_info("[ERROR] Error when map %lx to %lx. ret=%d\n",
// 			 	vma->vm_start + i * PAGE_SIZE, pfn, ret);
// 			return ret;
// 		}
// 	}

// 	return 0;
// }
static int procfile_mmap(struct file *file, struct vm_area_struct *vma)
{
    int ret;
    unsigned long size = vma->vm_end - vma->vm_start;
    unsigned long pfn;
    unsigned long i;

    if (vma->vm_pgoff != 0) {
        pr_info("[ERROR] mmap with non-zero vm_pgoff is not supported (vm_pgoff=%lu)\n", vma->vm_pgoff);
        return -EINVAL;
    }

    if (size < TRACER_REGION_SIZE) {
        pr_info("[ERROR] mmap range (0x%lx) too small. Need >= 0x%lx\n",
                size, (unsigned long)TRACER_REGION_SIZE);
        return -ENOMEM;
    }

    pr_info("[DEBUG] mmap called. size=0x%lx, prot=0x%x\n",
            size, (uint32_t)vma->vm_page_prot.pgprot);

    /* 6.11+: vm_flags 직접 수정 불가 → helper 사용 */
    vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP | VM_PFNMAP);

    /* DMA 버퍼는 캐시 끄는 게 안전 (stale cache 방지) */
    vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
    // 또는: vma->vm_page_prot = pgprot_writecombine(vma->vm_page_prot);

    for (i = 0; i < TRACER_REGION_SIZE / PAGE_SIZE; i++) {
        pfn = buf_pfn + i;
        ret = remap_pfn_range(vma,
                              vma->vm_start + i * PAGE_SIZE,
                              pfn,
                              PAGE_SIZE,
                              vma->vm_page_prot);
        if (ret) {
            pr_info("[ERROR] remap_pfn_range failed: va=0x%lx pfn=0x%lx ret=%d\n",
                    vma->vm_start + i * PAGE_SIZE, pfn, ret);
            return ret;
        }
    }

    return 0;
}

/**
 * ****************************
 * Memory Allocation Functions
 * ****************************
*/
static unsigned long allocate_tracer_region(int nid)
{
    pr_info("tracer alloc size %lx\n", TRACER_REGION_SIZE);
    if (TRACER_REGION_SIZE <= 0) return 0;

    unsigned long page_cnt = ALIGN(TRACER_REGION_SIZE, PAGE_SIZE) / PAGE_SIZE;
    struct page *head = NULL;
    unsigned long pa = 0;

    // all other kernel
    head = alloc_contig_pages(page_cnt, GFP_KERNEL | GFP_DMA32 | __GFP_ZERO, nid, NULL);
    // 6.11 damon
    //head = alloc_contig_pages_noprof(page_cnt, GFP_KERNEL | __GFP_ZERO, nid, NULL);

    if (!head)
        return 0;

    pa = PFN_PHYS(page_to_pfn(head));
    pr_info("tracer alloc %ld pages at %lx\n", page_cnt, pa);

    /* Safety: PAC DMA is likely 32-bit. Ensure buffer PA is below 4GB. */
    if (pa > DMA32_MAX_ADDR) {
        pr_err("[ERROR] tracer alloc got PA above 4GB: 0x%lx. This can corrupt OS if DMA addr is 32-bit (trunc -> 0x%08x).\n",
               pa, (u32)pa);
        free_contig_range(PHYS_PFN(pa), page_cnt);
        return 0;
    }

    return pa;
}


static void free_tracer_region(unsigned long pa)
{
	unsigned long page_cnt = ALIGN(TRACER_REGION_SIZE, PAGE_SIZE) / PAGE_SIZE;

	pr_info("tracer free %ld pages at %lx\n", page_cnt, pa);

	free_contig_range(PHYS_PFN(pa), page_cnt);
}
